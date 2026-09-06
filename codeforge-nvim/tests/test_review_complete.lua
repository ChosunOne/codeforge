do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
local Q = require("child_query") ---@type ChildQuery
F.set_child(child)
Q.set_child(child)

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
end

---Seed a one-modified-file change with two replace hunks.
local function seed_two_hunks()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })
	return path
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

-- ── A: dismiss teardown hardening ────────────────────────────────────────

T["dismiss removes the review keymaps from the buffer"] = function()
	local path = seed_two_hunks()
	local buf = open_review(path)

	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>a"), true, {
		fail_reason = "precondition: review keymaps installed",
	})

	child.lua(string.format([[require("codeforge.review.buffer").dismiss(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>a"), false, {
		fail_reason = "review keymaps must be removed by dismiss",
	})
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>d"), false, {
		fail_reason = "dismiss keymap itself must be removed",
	})
end

T["dismiss removes the reconcile autocmds from the buffer"] = function()
	local path = seed_two_hunks()
	local buf = open_review(path)

	local before = child.api.nvim_get_autocmds({ buffer = buf, event = { "TextChanged", "TextChangedI" } })
	MiniTest.expect.equality(#before > 0, true, { fail_reason = "precondition: reconcile autocmds installed" })

	child.lua(string.format([[require("codeforge.review.buffer").dismiss(%s)]], vim.inspect(path)))

	local after = child.api.nvim_get_autocmds({ buffer = buf, event = { "TextChanged", "TextChangedI" } })
	MiniTest.expect.equality(#after, 0, {
		fail_reason = "reconcile autocmds must be removed by dismiss, got " .. #after,
	})
end

-- ── B: state.complete_change ─────────────────────────────────────────────

T["complete_change finalizes reviews and removes the change with a log entry"] = function()
	local path = seed_two_hunks()
	local buf = open_review(path)
	-- triage: reject h2 (proposal row 4, 0-indexed 3), accept h1 (row 2, 0-indexed 1)
	child.lua(
		string.format(
			[[local r = require("codeforge.state").get_review(%s); r:reject_hunk(3); r:accept_hunk(1)]],
			vim.inspect(path)
		)
	)

	child.lua([[require("codeforge.state").complete_change(require("codeforge.state").get_current_change())]])

	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change()]]), vim.NIL, {
		fail_reason = "the change should be removed",
	})
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(path))),
		true,
		{ fail_reason = "the review record should be cleared" }
	)
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>a"), false, {
		fail_reason = "review keymaps should be torn down on completion",
	})
	Q.expect_lines("final content stays in the buffer", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"B",
		"c",
		"d",
		"e",
	})

	local log = child.lua_get([[require("codeforge.state").log]])
	MiniTest.expect.equality(#log, 1, { fail_reason = "completion should log one entry, got " .. vim.inspect(log) })
	MiniTest.expect.equality(log[1].status, "modified", {
		fail_reason = "mixed accept/reject derives as modified, got " .. tostring(log[1].status),
	})
end

T["maybe_complete leaves a pending change alone, completes a triaged one"] = function()
	local path = seed_two_hunks()
	open_review(path) -- both hunks pending
	local change = child.lua_get([[require("codeforge.state").get_current_change()]])

	local completed = child.lua_get(
		string.format(
			[[require("codeforge.state").maybe_complete(require("codeforge.state").get_current_change())]],
			vim.inspect(path)
		)
	)
	MiniTest.expect.equality(completed, false, { fail_reason = "pending change must not complete" })
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 1, {
		fail_reason = "pending change must stay tracked",
	})

	-- triage everything accepted -> maybe_complete should now fire
	child.lua(
		string.format([[local r = require("codeforge.state").get_review(%s); r:accept_pending()]], vim.inspect(path))
	)
	completed =
		child.lua_get([[require("codeforge.state").maybe_complete(require("codeforge.state").get_current_change())]])
	MiniTest.expect.equality(completed, true, { fail_reason = "fully-triaged change should complete" })
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "completed change should be removed",
	})
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").log]]), 1, {
		fail_reason = "completion should log exactly one entry",
	})
end

-- ── C: completion watcher hooks ──────────────────────────────────────────

T["accepting the last pending hunk via the row path completes the change"] = function()
	local path = seed_two_hunks()
	local buf = open_review(path)

	child.lua(
		string.format(
			[[local r = require("codeforge.state").get_review(%s); r:accept_hunk(1); r:accept_hunk(3)]],
			vim.inspect(path)
		)
	)

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "change should auto-complete after the last hunk is accepted",
	})
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(path))),
		true,
		{ fail_reason = "review record should be cleared" }
	)
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>a"), false, {
		fail_reason = "review keymaps should be gone after auto-completion",
	})
	Q.expect_lines("final content stays", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"B",
		"c",
		"D",
		"e",
	})
	local log = child.lua_get([[require("codeforge.state").log]])
	MiniTest.expect.equality(#log, 1, { fail_reason = "one decision-log entry" })
	MiniTest.expect.equality(log[1].status, "accepted", {
		fail_reason = "all-accepted derives as accepted, got " .. tostring(log[1].status),
	})
end

T["a reject sweep that triages everything completes the change"] = function()
	local path = seed_two_hunks()
	open_review(path)

	child.lua_get([[require("codeforge.sidebar.actions").reject_pending()]])

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "all-rejected change should auto-complete after the sweep",
	})
	local log = child.lua_get([[require("codeforge.state").log]])
	MiniTest.expect.equality(log[1].status, "rejected", {
		fail_reason = "all-rejected derives as rejected, got " .. tostring(log[1].status),
	})
end

T["conflicted hunks block completion"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, { "a", "b-user", "c", "d" })
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	open_review(path)
	child.lua(
		string.format([[require("codeforge.state").get_review(%s).hunk_status.h1 = "conflicted"]], vim.inspect(path))
	)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_pending()]], vim.inspect(path)))

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 1, {
		fail_reason = "a conflicted hunk must keep the change pending",
	})
end

T["an atomic decision flip can be the last piece that completes a change"] = function()
	local OA = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(OA, pa)
	local added = F.tmp_path()
	child.lua(
		string.format(
			[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "Mixed",
                        files = {
                                { path = %s, status = "modified", base = %s, hunks = { %s } },
                                { path = %s, status = "added", hunks = {} },
                        },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
			vim.inspect(pa),
			vim.inspect(OA),
			vim.inspect(F.replace_hunk("a-h1", 2, "a2", "A2")),
			vim.inspect(added)
		)
	)

	-- triage the hunk via the row path (does not touch atomic files)
	open_review(pa)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(pa)))
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 1, {
		fail_reason = "undecided atomic file keeps the change pending",
	})

	-- deciding the added file completes the change
	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(added)))
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "decision flip should complete the change",
	})
end

return T
