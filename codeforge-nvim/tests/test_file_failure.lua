do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

local O = { "a", "b", "c", "d", "e" }

---Seed a two-hunk modified change and return its path.
local function seed()
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })
	return path
end

---Pretend every hunk was accepted without building a buffer.
local function accept_all(path)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reviews[%s] = { hunk_status = { h1 = "accepted", h2 = "accepted" }, user_modified = false }
		]],
		vim.inspect(path)
	))
end

local function mark(path, reason)
	return child.lua_get(
		string.format(
			[[require("codeforge.state").mark_file_failed("change-001", %s, %s)]],
			vim.inspect(path),
			vim.inspect(reason)
		)
	)
end

local function failures(path)
	return child.lua_get(
		string.format(
			[[(function() local s = require("codeforge.state") for _, f in ipairs(s.changes[1].files) do if f.path == %s then return f.failures end end end)()]],
			vim.inspect(path)
		)
	)
end

local function derived()
	return child.lua_get([[require("codeforge.state").derive_status(require("codeforge.state").changes[1])]])
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.lua([[
				local state = require("codeforge.state")
				state.reset()
				state.log_file = nil
			]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

T["marking a part failed records the reason on that file only"] = function()
	local a = seed()
	local b = F.tmp_path()
	child.fn.writefile(O, b)
	child.lua(string.format(
		[[
			local s = require("codeforge.state")
			table.insert(s.changes[1].files, { path = %s, status = "modified", base = %s, hunks = {} })
		]],
		vim.inspect(b),
		vim.inspect(O)
	))

	MiniTest.expect.equality(mark(a, "target no longer exists on disk"), true)

	local recorded = failures(a)[1]
	MiniTest.expect.equality(recorded.reason, "target no longer exists on disk")
	MiniTest.expect.equality(type(recorded.at), "number")
	-- The sibling part is untouched: failures are per-part, not per-change.
	MiniTest.expect.equality(failures(b), vim.NIL)
end

T["re-marking the same reason refreshes it instead of stacking duplicates"] = function()
	local path = seed()
	mark(path, "open failed")
	mark(path, "open failed")
	MiniTest.expect.equality(#failures(path), 1)
	local first = failures(path)[1].at

	mark(path, "merge failed")
	MiniTest.expect.equality(#failures(path), 2)
	MiniTest.expect.equality(failures(path)[2].reason, "merge failed")
	MiniTest.expect.equality(failures(path)[1].at >= first, true)
end

T["an unknown change or file is a no-op rather than an error"] = function()
	local path = seed()
	MiniTest.expect.equality(mark(path, "x"), true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").mark_file_failed("nope", "x", "r")]]), false)
	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[[require("codeforge.state").mark_file_failed("change-001", %s, "r")]],
				vim.inspect(F.tmp_path())
			)
		),
		false
	)
end

T["a failed part keeps an otherwise fully accepted change from deriving accepted"] = function()
	local path = seed()
	accept_all(path)
	MiniTest.expect.equality(derived(), "accepted")

	mark(path, "target no longer exists on disk")
	-- The log is what tells the agent what happened; it must not claim the
	-- whole file was taken wholesale when a part never applied.
	MiniTest.expect.equality(derived(), "modified")
end

T["a failed part is visible in the sidebar glyph and its highlight"] = function()
	local path = seed()
	accept_all(path)
	local ok_glyph = child.lua_get(
		[[{require("codeforge.state").file_status_glyph(require("codeforge.state").changes[1].files[1])}]]
	)
	-- Only failures change the glyph; a clean all-accepted file stays "●".
	MiniTest.expect.equality(ok_glyph[1], "●")

	mark(path, "target no longer exists on disk")
	local glyph, hl = unpack(
		child.lua_get(
			[[{require("codeforge.state").file_status_glyph(require("codeforge.state").changes[1].files[1])}]]
		)
	)
	MiniTest.expect.equality(glyph, "⚠")
	MiniTest.expect.equality(hl, "CodeForgeReviewFailed")
end

T["clearing the last failure returns the part to its normal outcome"] = function()
	local path = seed()
	accept_all(path)
	mark(path, "target no longer exists on disk")

	child.lua(
		[[require("codeforge.state").clear_file_failure(require("codeforge.state").changes[1].files[1], "target no longer exists on disk")]]
	)
	MiniTest.expect.equality(failures(path), vim.NIL)
	MiniTest.expect.equality(derived(), "accepted")
end

T["clearing one failure keeps the others"] = function()
	local path = seed()
	accept_all(path)
	mark(path, "open failed")
	mark(path, "merge failed")
	child.lua(
		[[require("codeforge.state").clear_file_failure(require("codeforge.state").changes[1].files[1], "open failed")]]
	)
	MiniTest.expect.equality(#failures(path), 1)
	MiniTest.expect.equality(failures(path)[1].reason, "merge failed")
end

T["reset drops failures with the change they belonged to"] = function()
	local path = seed()
	mark(path, "open failed")
	child.lua([[require("codeforge.state").reset()]])
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
end

T["opening a part whose target vanished records the failure and opens no review"] = function()
	-- The file was never written: a `modified` part with nothing on disk.
	local path = F.tmp_path()
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(path))),
		true
	)
	local recorded = failures(path)[1]
	MiniTest.expect.equality(recorded.reason, "target no longer exists on disk")
	-- The decision must not be implied accepted by a failed open.
	MiniTest.expect.equality(derived(), "pending")
end

T["a failed part does not stop the rest of the change from being reviewed"] = function()
	local missing = F.tmp_path()
	local present = F.tmp_path()
	child.fn.writefile(O, present)
	F.seed_change(missing, O, { F.replace_hunk("h1", 2, "b", "B") })
	child.lua(string.format(
		[[
			local s = require("codeforge.state")
			s.changes[1].files[2] = { path = %s, status = "modified", base = %s, hunks = %s }
		]],
		vim.inspect(present),
		vim.inspect(O),
		vim.inspect({ F.replace_hunk("h2", 4, "d", "D") })
	))

	-- A sweep should handle the readable part and record only the failed one.
	child.lua([[require("codeforge.sidebar.actions").accept_pending()]])
	MiniTest.expect.equality(failures(missing)[1].reason, "target no longer exists on disk")
	MiniTest.expect.equality(
		child.lua_get(
			string.format([[(require("codeforge.state").get_review(%s) or {}).hunk_status.h2]], vim.inspect(present))
		),
		"accepted"
	)
	MiniTest.expect.equality(failures(present), vim.NIL)
end

return T
