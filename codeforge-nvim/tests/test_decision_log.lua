do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

---@param value table
local function request(value)
	return child.lua_get(string.format([[require("codeforge.protocol").handle(%q)]], vim.json.encode(value)))
end

local function use_log(path)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.log_file = %s
		]],
		path and vim.inspect(path) or "nil"
	))
end

local function append(id, ts, status)
	child.lua(string.format(
		[[
			require("codeforge.state").append_log({
				id = %q, title = %q, timestamp = %d, status = %q,
				files = { { path = "/p/%s.lua", status = "modified", modified = false,
					hunks = { { id = %q, status = %q } } } },
			})
		]],
		id,
		"title " .. id,
		ts,
		status,
		id,
		id .. "-h1",
		status
	))
end

---Every non-empty line of the log file, whatever its shape.
local function raw_log(path)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	return table.concat(vim.fn.readfile(path), "\n")
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

-- ── format ─────────────────────────────────────────────────────────────────

T["the log is one JSON object per line, not a JSON array"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-a", 1, "accepted")
	append("cf-b", 2, "rejected")

	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(#lines, 2)
	-- Each line must stand alone: decoding any single line must yield one entry.
	for i, line in ipairs(lines) do
		local ok, decoded = pcall(vim.json.decode, line)
		MiniTest.expect.equality(ok, true, { fail_reason = "line " .. i .. " is not JSON: " .. line })
		MiniTest.expect.equality(type(decoded), "table")
		MiniTest.expect.equality(decoded.id ~= nil, true, { fail_reason = "line " .. i .. " has no id" })
	end
	-- The old whole-file-array shape must not be what we write.
	local whole = raw_log(p)
	local ok_array = pcall(vim.json.decode, whole)
	MiniTest.expect.equality(ok_array, false, {
		fail_reason = "the file as a whole must not decode as one JSON value",
	})
end

T["appending never rewrites existing entries (append-only)"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-first", 1, "accepted")
	local first_bytes = raw_log(p)

	-- The first line must be byte-identical after later appends: an append-only
	-- file is what makes the write O(1) instead of read-rewrite-whole.
	append("cf-second", 2, "accepted")
	append("cf-third", 3, "accepted")
	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(lines[1], first_bytes)
	MiniTest.expect.equality(#lines, 3)
end

T["timestamps and title survive a round trip through the file"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-rt", 1234, "modified")
	use_log(p) -- forget memory, re-read from disk
	local entry = child.lua_get([=[require("codeforge.state").read_log_file()[1]]=])
	MiniTest.expect.equality(entry.id, "cf-rt")
	MiniTest.expect.equality(entry.timestamp, 1234)
	MiniTest.expect.equality(entry.title, "title cf-rt")
	MiniTest.expect.equality(entry.status, "modified")
	MiniTest.expect.equality(entry.files[1].hunks[1].status, "modified")
end

-- ── migration ──────────────────────────────────────────────────────────────

T["an existing JSON-array log is migrated to JSONL on first read"] = function()
	local p = F.tmp_path("_log.json")
	local legacy = {
		{ id = "cf-old-1", title = "old one", timestamp = 10, status = "accepted", files = {} },
		{ id = "cf-old-2", title = "old two", timestamp = 20, status = "rejected", files = {} },
	}
	vim.fn.writefile({ vim.json.encode(legacy) }, p)

	use_log(p)
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 2, { fail_reason = "both legacy entries must be readable" })
	MiniTest.expect.equality(entries[1].id, "cf-old-1")
	MiniTest.expect.equality(entries[2].id, "cf-old-2")

	-- A subsequent append must preserve the migrated entries and land in JSONL.
	append("cf-new", 30, "accepted")
	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(#lines, 3, { fail_reason = "migration must not drop or duplicate entries" })
	MiniTest.expect.equality(pcall(vim.json.decode, raw_log(p)), false)
end

T["migration is idempotent: reading twice does not duplicate entries"] = function()
	local p = F.tmp_path("_log.json")
	vim.fn.writefile(
		{ vim.json.encode({
			{ id = "cf-once", title = "t", timestamp = 5, status = "accepted", files = {} },
		}) },
		p
	)
	use_log(p)
	child.lua([[require("codeforge.state").read_log_file()]])
	child.lua([[require("codeforge.state").read_log_file()]])
	append("cf-twice", 6, "accepted")
	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(#lines, 2, { fail_reason = "entries must not be duplicated by migration" })
end

T["a legacy array with JSONL appended loses nothing (mid-upgrade state)"] = function()
	-- The dangerous case: an old array file that an upgraded writer has since
	-- appended a line to. The whole-file decode fails, so a naive migration
	-- would rewrite an empty log over it.
	local p = F.tmp_path("_log.json")
	local legacy = vim.json.encode({
		{ id = "cf-old-1", title = "one", timestamp = 1, status = "accepted", files = {} },
		{ id = "cf-old-2", title = "two", timestamp = 2, status = "rejected", files = {} },
	})
	local appended = vim.json.encode({ id = "cf-new", title = "new", timestamp = 3, status = "accepted", files = {} })
	vim.fn.writefile({ legacy, appended }, p)
	local before = vim.fn.getfsize(p)

	use_log(p)
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(vim.fn.getfsize(p) > 0, true, {
		fail_reason = "the log must never be truncated to empty (was " .. before .. " bytes)",
	})
	MiniTest.expect.equality(#entries, 3, { fail_reason = "all three entries must be recoverable" })
	MiniTest.expect.equality(entries[3].id, "cf-new")
end

T["an unparseable file is left untouched rather than truncated"] = function()
	local p = F.tmp_path("_log.json")
	vim.fn.writefile({ "[ this looks like an array but is broken", "garbage" }, p)
	local before = vim.fn.getfsize(p)
	use_log(p)
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 0)
	MiniTest.expect.equality(vim.fn.getfsize(p), before, {
		fail_reason = "a file we cannot parse must not be overwritten",
	})
end

T["an empty array migrates cleanly without inventing entries"] = function()
	local p = F.tmp_path("_log.json")
	vim.fn.writefile({ "[]" }, p)
	use_log(p)
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").read_log_file()]]), 0)
	append("cf-after-empty", 1, "accepted")
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 1)
	MiniTest.expect.equality(entries[1].id, "cf-after-empty")
end

-- ── robustness ─────────────────────────────────────────────────────────────

T["a corrupt line is skipped, and the rest of the log still reads"] = function()
	local p = F.tmp_path("_log.json")
	local good = vim.json.encode({ id = "cf-good", title = "t", timestamp = 1, status = "accepted", files = {} })
	vim.fn.writefile({ good, "{ this is not json", good, "" }, p)
	use_log(p)
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 2, { fail_reason = "the two good lines must be returned" })
	for _, e in ipairs(entries) do
		MiniTest.expect.equality(e.id, "cf-good")
	end
end

T["a partial trailing line (crash mid-append) does not hide earlier entries"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-complete", 1, "accepted")
	-- Simulate a crash that left half a line behind.
	local f = assert(io.open(p, "a"))
	f:write('{"id":"cf-trunca')
	f:close()

	use_log(p)
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 1)
	MiniTest.expect.equality(entries[1].id, "cf-complete")
end

T["entries without a usable id are ignored rather than poisoning the log"] = function()
	local p = F.tmp_path("_log.json")
	vim.fn.writefile({
		vim.json.encode({ id = "cf-ok", timestamp = 1, status = "accepted", files = {} }),
		vim.json.encode({ timestamp = 2, status = "accepted" }), -- no id
		vim.json.encode({ id = 123, timestamp = 3 }), -- id not a string
	}, p)
	use_log(p)
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 1)
	MiniTest.expect.equality(entries[1].id, "cf-ok")
end

T["an unwritable log path fails loudly once and never breaks the review flow"] = function()
	-- A directory where the file should be: the append cannot succeed.
	local dir = F.tmp_path("_is_a_dir")
	child.fn.mkdir(dir, "p")
	use_log(dir)

	local ok = child.lua_get(
		[[{ pcall(require("codeforge.state").append_log, { id = "cf-x", status = "accepted", files = {} }) }]]
	)
	MiniTest.expect.equality(ok[1], true, { fail_reason = "append must not throw: " .. tostring(ok[2]) })
	-- In-memory state stays consistent so review can continue.
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 1)
end

T["a missing log directory is created"] = function()
	local dir = F.tmp_path("_nested")
	use_log(dir .. "/deep/log.jsonl")
	append("cf-mkdir", 1, "accepted")
	MiniTest.expect.equality(vim.fn.filereadable(dir .. "/deep/log.jsonl"), 1)
end

T["persistence off keeps the in-memory log working"] = function()
	use_log(nil)
	append("cf-mem", 1, "accepted")
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 1)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").read_log_file()]]), 0)
end

-- ── reading is not quadratic, and the cache is honest ──────────────────────

T["the decoded log is cached between calls and invalidated by an append"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-one", 1, "accepted")

	local first = child.lua_get([[require("codeforge.state").read_log_file()]])
	-- Mutating the returned table must not corrupt later reads: callers get a
	-- detached copy, not the cache itself.
	child.lua([=[require("codeforge.state").read_log_file()[1].id = "mutated"]=])
	local second = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(second[1].id, "cf-one", { fail_reason = "callers must not share the cache" })

	-- An append must invalidate, so the new entry is visible.
	append("cf-two", 2, "accepted")
	local third = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#third, 2)
	MiniTest.expect.equality(#first, 1)
end

T["an external change to the file is picked up rather than served from cache"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-internal", 1, "accepted")
	child.lua([[require("codeforge.state").read_log_file()]]) -- prime the cache

	-- Another Neovim (or a restart) writes to the same file.
	local f = assert(io.open(p, "a"))
	f:write(
		vim.json.encode({ id = "cf-external", title = "x", timestamp = 2, status = "accepted", files = {} }) .. "\n"
	)
	f:close()

	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 2, { fail_reason = "an external append must be observed" })
end

T["a list request scans the log once, not once per page and total"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	for i = 1, 5 do
		append(("cf-scan-%d"):format(i), i, "accepted")
	end
	-- Counting the internal read distinguishes "one decode" from the
	-- page/total split that previously decoded the whole log twice per request.
	child.lua([[
		_G.__reads = 0
		local state = require("codeforge.state")
		local orig = state._read_log_raw
		state._read_log_raw = function(...)
			_G.__reads = _G.__reads + 1
			return orig(...)
		end
	]])
	local reply = request({ op = "list", limit = 2 })
	MiniTest.expect.equality(reply.result.total, 5)
	MiniTest.expect.equality(#reply.result.changes, 2)
	MiniTest.expect.equality(child.lua_get([[_G.__reads]]), 1, {
		fail_reason = "one list request must read the log exactly once",
	})
end

T["paging still visits every change exactly once after the format change"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	for i = 1, 7 do
		append(("cf-page-%02d"):format(i), 100 + i, "accepted")
	end
	local seen = {}
	local cursor = vim.NIL
	local guard = 0
	repeat
		local reply = request({ op = "list", limit = 3, cursor = cursor })
		MiniTest.expect.equality(reply.ok, true)
		for _, row in ipairs(reply.result.changes) do
			seen[#seen + 1] = row.id
		end
		cursor = reply.result.next_cursor
		guard = guard + 1
		MiniTest.expect.equality(guard < 10, true)
	until cursor == vim.NIL
	MiniTest.expect.equality(#seen, 7)
	MiniTest.expect.equality(seen, {
		"cf-page-07",
		"cf-page-06",
		"cf-page-05",
		"cf-page-04",
		"cf-page-03",
		"cf-page-02",
		"cf-page-01",
	})
end

T["status still resolves an outcome from the persisted log"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-persisted", 7, "rejected")
	use_log(p) -- forget the session, as a restart would
	local reply = request({ op = "status", id = "cf-persisted" })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.status, "rejected")
	MiniTest.expect.equality(reply.result.under_review, false)
end

T["the newest real outcome still wins over an older one and a reopen marker"] = function()
	local p = F.tmp_path("_log.json")
	use_log(p)
	append("cf-round", 100, "rejected")
	append("cf-round", 200, "reopened")
	append("cf-round", 300, "accepted")
	use_log(p)
	local reply = request({ op = "status", id = "cf-round" })
	MiniTest.expect.equality(reply.result.status, "accepted")
end

return T
