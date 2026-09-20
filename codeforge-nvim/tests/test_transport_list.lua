do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

local log_path

local function request(value)
	return child.lua_get(string.format([[require("codeforge.protocol").handle(%q)]], vim.json.encode(value)))
end

local function list(opts)
	local req = { op = "list" }
	for k, v in pairs(opts or {}) do
		req[k] = v
	end
	return request(req)
end

---Seed one tracked change whose derived status is already decided (an atomic
---file needs no buffer), so listing needs no review machinery.
local function seed_live(id, ts, decision)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.changes[#state.changes + 1] = {
				id = %q,
				title = "title of " .. %q,
				timestamp = %d,
				files = { {
					path = "/project/" .. %q .. ".lua",
					status = "added",
					decision = %q,
					hunks = { { id = %q .. "-h1", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+x" } } },
				} },
			}
			state.current_change_index = 1
			state.current_change_id = state.changes[1].id
		]],
		id,
		id,
		ts,
		id,
		decision or "accepted",
		id
	))
end

---Write a decision-log entry: through state (so it reaches disk) when
---`durable`, directly into memory otherwise.
local function seed_entry(id, ts, status, durable)
	local entry = {
		id = id,
		title = "title of " .. id,
		timestamp = ts,
		status = status,
		files = {
			{
				path = "/project/" .. id .. ".lua",
				status = "modified",
				modified = false,
				hunks = { { id = id .. "-h1", status = status == "reopened" and nil or status } },
			},
		},
	}
	if durable then
		child.lua(string.format([[require("codeforge.state").append_log(%s)]], vim.inspect(entry)))
	else
		child.lua(string.format([[table.insert(require("codeforge.state").log, %s)]], vim.inspect(entry)))
	end
end

local function ids_of(reply)
	local out = {}
	for _, row in ipairs(reply.result.changes) do
		out[#out + 1] = row.id
	end
	return out
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			log_path = vim.fn.tempname() .. "_list_log.json"
			child.lua(string.format(
				[[
					local state = require("codeforge.state")
					state.reset()
					state.log_file = %q
				]],
				log_path
			))
		end,
		post_case = function()
			F.cleanup()
			os.remove(log_path)
		end,
		post_once = child.stop,
	},
})

-- ── shape and ordering ─────────────────────────────────────────────────────

T["an empty editor lists nothing and offers no next cursor"] = function()
	local reply = list()
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(#reply.result.changes, 0)
	MiniTest.expect.equality(reply.result.total, 0)
	MiniTest.expect.equality(reply.result.has_more, false)
	MiniTest.expect.equality(reply.result.next_cursor, vim.NIL)
end

T["rows are summaries, not full change statuses"] = function()
	seed_live("cf-live-1", 100, "accepted")
	local row = list().result.changes[1]
	-- The exact field set is asserted so a future addition is deliberate: a
	-- list row must stay small, with `status` the place to ask for detail.
	local keys = {}
	for k in pairs(row) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	MiniTest.expect.equality(keys, { "id", "status", "timestamp", "title", "under_review" })
	MiniTest.expect.equality(row.title, "title of cf-live-1")
	MiniTest.expect.equality(row.status, "accepted")
	MiniTest.expect.equality(row.under_review, true)
end

T["newest first, across tracked, completed and persisted changes"] = function()
	seed_live("cf-live-new", 300, "accepted")
	seed_entry("cf-session-old", 100, "rejected", false)
	seed_entry("cf-disk-old", 200, "accepted", true)
	local reply = list()
	MiniTest.expect.equality(ids_of(reply), { "cf-live-new", "cf-disk-old", "cf-session-old" })
	MiniTest.expect.equality(reply.result.total, 3)
end

T["equal timestamps break deterministically by id"] = function()
	-- Same second, so only the id can order these; re-asking must not shuffle.
	for _, id in ipairs({ "cf-tie-a", "cf-tie-c", "cf-tie-b" }) do
		seed_entry(id, 500, "accepted", false)
	end
	local first = ids_of(list())
	MiniTest.expect.equality(first, ids_of(list()))
	MiniTest.expect.equality(first, { "cf-tie-c", "cf-tie-b", "cf-tie-a" })
end

T["a change known from several sources appears once, live state winning"] = function()
	seed_entry("cf-dup", 100, "rejected", true)
	seed_entry("cf-dup", 150, "accepted", true)
	seed_live("cf-dup", 120, "accepted")
	local reply = list()
	MiniTest.expect.equality(#reply.result.changes, 1, { fail_reason = "duplicate ids must collapse" })
	MiniTest.expect.equality(reply.result.total, 1)
	local row = reply.result.changes[1]
	MiniTest.expect.equality(row.under_review, true)
	MiniTest.expect.equality(row.timestamp, 120)
	MiniTest.expect.equality(row.status, "accepted")
end

T["the newest real outcome is reported, not a later reopen marker"] = function()
	seed_entry("cf-round", 100, "rejected", true)
	seed_entry("cf-round", 200, "reopened", true)
	seed_entry("cf-round", 300, "accepted", true)
	local row = list().result.changes[1]
	MiniTest.expect.equality(row.status, "accepted")
	MiniTest.expect.equality(row.under_review, false)
end

T["a change completed in an earlier session is listed after a restart"] = function()
	seed_entry("cf-earlier", 42, "modified", true)
	child.lua([[require("codeforge.state").reset()]])
	child.lua(string.format([[require("codeforge.state").log_file = %q]], log_path))
	local reply = list()
	MiniTest.expect.equality(ids_of(reply), { "cf-earlier" })
	MiniTest.expect.equality(reply.result.changes[1].status, "modified")
end

T["listing is read-only and never completes a tracked change"] = function()
	seed_live("cf-stays", 10, "accepted")
	child.lua([[
		_G.__before = { bufs = vim.api.nvim_list_bufs(), n = #require("codeforge.state").changes, log = #require("codeforge.state").log }
	]])
	list()
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), child.lua_get([[_G.__before.log]]))
	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(_G.__before.bufs, vim.api.nvim_list_bufs())]]), true)
end

-- ── pagination ─────────────────────────────────────────────────────────────

T["page size is bounded by a default and a maximum"] = function()
	for i = 1, 25 do
		seed_entry(("cf-many-%02d"):format(i), 1000 + i, "accepted", false)
	end
	local page = list()
	MiniTest.expect.equality(#page.result.changes, 20, { fail_reason = "default limit is 20" })
	MiniTest.expect.equality(page.result.total, 25)
	MiniTest.expect.equality(page.result.has_more, true)
	MiniTest.expect.equality(type(page.result.next_cursor), "string")

	local capped = list({ limit = 100 })
	MiniTest.expect.equality(#capped.result.changes, 25)
	MiniTest.expect.equality(capped.result.has_more, false)
	MiniTest.expect.equality(capped.result.next_cursor, vim.NIL)
end

T["a limit larger than the maximum is refused, not silently clamped"] = function()
	local reply = list({ limit = 101 })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_request")
	for _, bad in ipairs({ 0, -1, 1.5, "20", true }) do
		local r = list({ limit = bad })
		MiniTest.expect.equality(r.ok, false, { fail_reason = "limit " .. vim.inspect(bad) .. " must be refused" })
	end
end

T["walking the cursor visits every change exactly once"] = function()
	local want = {}
	for i = 1, 7 do
		local id = ("cf-walk-%02d"):format(i)
		want[#want + 1] = id
		seed_entry(id, 2000 + i, "accepted", false)
	end
	table.sort(want, function(a, b)
		return a > b
	end)

	local start = vim.NIL
	local seen = {}
	local pages = 0
	repeat
		local reply = list({ limit = 3, cursor = start })
		MiniTest.expect.equality(reply.ok, true)
		pages = pages + 1
		for _, id in ipairs(ids_of(reply)) do
			seen[#seen + 1] = id
		end
		start = reply.result.next_cursor
		MiniTest.expect.equality(pages < 10, true, { fail_reason = "pagination did not terminate" })
	until start == vim.NIL

	MiniTest.expect.equality(#seen, 7, { fail_reason = "each change must appear exactly once" })
	local unique = {}
	for _, id in ipairs(seen) do
		unique[id] = (unique[id] or 0) + 1
	end
	for id, count in pairs(unique) do
		MiniTest.expect.equality(count, 1, { fail_reason = id .. " appeared " .. count .. " times" })
	end
	MiniTest.expect.equality(seen, want)
end

T["the last page reports no cursor, and a cursor at the end yields nothing"] = function()
	seed_entry("cf-only", 5, "accepted", false)
	local first = list({ limit = 1 })
	MiniTest.expect.equality(first.result.has_more, false)
	MiniTest.expect.equality(first.result.next_cursor, vim.NIL)
end

T["a malformed or unknown cursor is refused rather than guessed at"] = function()
	seed_entry("cf-cursor", 5, "accepted", false)
	for _, bad in ipairs({ 42, true, {}, "not-a-cursor", "%%%", "1:2:3" }) do
		local reply = list({ cursor = bad })
		MiniTest.expect.equality(reply.ok, false, {
			fail_reason = "cursor " .. vim.inspect(bad) .. " must be refused",
		})
		MiniTest.expect.equality(reply.error.code, "invalid_request")
	end
end

T["a stale cursor resumes at the right place rather than skipping or repeating"] = function()
	for i = 1, 6 do
		seed_entry(("cf-stale-%02d"):format(i), 3000 + i, "accepted", false)
	end
	local page = list({ limit = 2 })
	local cursor = page.result.next_cursor
	-- A newer change arrives between pages: newest-first paging must not shift
	-- the rows a cursor has already passed.
	seed_entry("cf-arrived", 5000, "accepted", false)
	local next_page = list({ limit = 2, cursor = cursor })
	local ids = ids_of(next_page)
	MiniTest.expect.equality(vim.tbl_contains(ids, "cf-arrived"), false, {
		fail_reason = "an older cursor must not surface newer rows",
	})
	MiniTest.expect.equality(ids, { "cf-stale-04", "cf-stale-03" })
end

T["list validates its allowlist and accepts no mutation fields"] = function()
	for _, extra in ipairs({
		{ proposal = {} },
		{ id = "x" },
		{ path = "/etc/passwd" },
		{ lua = "vim.g.pwn = 1" },
	}) do
		local req = { op = "list" }
		for k, v in pairs(extra) do
			req[k] = v
		end
		local reply = request(req)
		MiniTest.expect.equality(reply.ok, false, { fail_reason = vim.inspect(extra) .. " must be refused" })
		MiniTest.expect.equality(reply.error.code, "invalid_request")
	end
	MiniTest.expect.equality(child.lua_get([[vim.g.pwn]]), vim.NIL)
end

return T
