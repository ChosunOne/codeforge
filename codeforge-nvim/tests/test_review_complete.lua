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

T["final assembly survives coordinate drift from a pre-review insertion"] = function()
	local O = { "a", "b", "c", "d" }
	local U = { "a", "USER", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 3, "c", "C") })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(2)]], vim.inspect(path)))

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "accepting the only hunk should complete the change",
	})
	Q.expect_lines("drifted U edit and accepted hunk both kept", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"USER",
		"b",
		"C",
		"d",
	})
end

T["undo restores the exact pre-action buffer; U stays in the snapshot; redo preserves it"] = function()
	local O = { "a", "b", "c", "d" }
	local U = { "USER", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))
	Q.expect_lines("completed final", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "USER", "B", "c", "d" })

	child.lua_get([[require("codeforge.sidebar.actions").undo()]])

	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(path))),
		true,
		{ fail_reason = "undo should revive the review" }
	)
	-- Undo restores the exact pre-action buffer (editor-undo semantics), which
	-- was the proposal P before the accept. The unrelated pre-review edit lives
	-- in the snapshot U and must NOT be baked into the restored P.
	Q.expect_lines("revived buffer is the exact pre-accept P", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"B",
		"c",
		"d",
	})
	Q.expect_lines(
		"U still holds the unrelated edit",
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(path))),
		U
	)

	-- redo re-completes and the final assembly still recovers U's unrelated edit
	MiniTest.expect.equality(child.lua_get([[require("codeforge.sidebar.actions").redo()]]), 1, {
		fail_reason = "redo should re-apply the accept",
	})
	Q.expect_lines("re-completed final", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"USER",
		"B",
		"c",
		"d",
	})
end

T["a during-review deletion of a whole gap is not resurrected by U"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	-- delete the trailing line outside the hunk while reviewing
	child.api.nvim_buf_set_lines(buf, 2, 3, false, {})
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	Q.expect_lines("the during-review deletion is respected", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"B",
	})
end

T["a U insertion at the start of the file survives final assembly"] = function()
	local O = { "b", "c" }
	local U = { "NEW", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "c", "C") })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	Q.expect_lines("the leading U insertion survives", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"NEW",
		"b",
		"C",
	})
end

T["disjoint pre-review and during-review gap edits both survive"] = function()
	-- O has distinct gap lines above and below the hunk; U edits the gap line
	-- above the hunk pre-review, and the user edits the gap line below during
	-- review. Both edits sit in different parts of the same gap region.
	local O = { "g1", "b", "g2", "c" }
	local U = { "G1", "b", "g2", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	-- edit the other trailing gap line during review (row 2 is 'g2')
	child.api.nvim_buf_set_lines(buf, 2, 3, false, { "G2" })
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	Q.expect_lines("both gap edits survive", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"G1",
		"B",
		"G2",
		"c",
	})
end

T["a U insertion before a hunk on line 1 is not dropped"] = function()
	local O = { "b" }
	local U = { "NEW", "b" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 1, "b", "B") })

	local buf = open_review(path)
	Q.expect_lines("preview P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "B" })
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(0)]], vim.inspect(path)))

	Q.expect_lines("leading insertion before the hunk survives", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"NEW",
		"B",
	})
end

T["a U insertion after the last hunk is not dropped"] = function()
	local O = { "b" }
	local U = { "b", "NEW" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 1, "b", "B") })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(0)]], vim.inspect(path)))

	Q.expect_lines("trailing insertion after the hunk survives", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"B",
		"NEW",
	})
end

T["a pure-insertion hunk keeps user edits on both sides"] = function()
	local O = { "a", "c" }
	local U = { "A", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	-- insert X before base line 2 (between 'a' and 'c')
	F.seed_change(path, O, { F.insert_hunk("h1", 2, { "X" }) })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	Q.expect_lines("the pre-review edit above the insertion survives", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"A",
		"X",
		"c",
	})
end

T["accepting the last hunk preserves user edits outside the hunks"] = function()
	local O = { "a", "b", "c" }
	local U = { "USER", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "accepting the only hunk should complete the change",
	})
	Q.expect_lines("final keeps the unrelated U edit", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"USER",
		"B",
		"c",
	})
end

T["a hand edit made during review outside the hunks survives completion"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	-- hand-edit a line outside the proposed hunk, during review
	child.api.nvim_buf_set_lines(buf, 3, 4, false, { "D-edit" })
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	Q.expect_lines("final keeps the during-review hand edit", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"B",
		"c",
		"D-edit",
	})
end

T["accepting a previewed added file keeps during-review hand edits"] = function()
	local path = F.tmp_path()
	local lines = { "NEW_CONTENT" }
	F.seed_added_file(path, lines)

	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(path)))
	local buf = Q.find_buf(path)
	-- hand-edit the preview before accepting
	child.api.nvim_buf_set_lines(buf, 0, -1, false, { "HAND_EDITED" })

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(path)))

	Q.expect_lines("the previewed hand edit is kept", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "HAND_EDITED" })
end

T["rejecting a deleted-file decision restores the user's unsaved content"] = function()
	local O = { "disk1", "disk2" }
	local U = { "unsaved1", "unsaved2" }
	local del = F.tmp_path()
	child.fn.writefile(O, del)

	-- second, still-pending file keeps the change tracked across both toggles
	local O2 = { "o1", "o2" }
	local other = F.tmp_path()
	child.fn.writefile(O2, other)

	child.cmd("edit " .. del)
	child.api.nvim_buf_set_lines(Q.find_buf(del), 0, -1, false, U)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { { id = "change-001", title = "T", files = {
                        { path = %s, status = "deleted", base = %s, hunks = { { id = "d1", old_start = 1, old_lines = 2, new_start = 1, new_lines = 0, lines = { "-disk1", "-disk2" } } } },
                        { path = %s, status = "modified", base = %s, hunks = { { id = "m1", old_start = 1, old_lines = 1, new_start = 1, new_lines = 1, lines = { "-o1", "+O1" } } } },
                } } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		vim.inspect(del),
		vim.inspect(O),
		vim.inspect(other),
		vim.inspect(O2)
	))

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(del))) -- accepted
	Q.expect_lines("accepted deletion empties the buffer", child.api.nvim_buf_get_lines(Q.find_buf(del), 0, -1, false), {
		"",
	})
	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(del))) -- rejected

	Q.expect_lines(
		"reject restores the user's unsaved content, not the on-disk base",
		child.api.nvim_buf_get_lines(Q.find_buf(del), 0, -1, false),
		U
	)
end

T["undoing an atomic decision restores the exact pre-action buffer"] = function()
	local O = { "disk1", "disk2" }
	local U = { "edited1", "edited2" }
	local del = F.tmp_path()
	child.fn.writefile(O, del)
	child.cmd("edit " .. del)
	child.api.nvim_buf_set_lines(Q.find_buf(del), 0, -1, false, U)

	local O2 = { "o1", "o2" }
	local other = F.tmp_path()
	child.fn.writefile(O2, other)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { { id = "change-001", title = "T", files = {
                        { path = %s, status = "deleted", base = %s, hunks = { { id = "d1", old_start = 1, old_lines = 2, new_start = 1, new_lines = 0, lines = { "-disk1", "-disk2" } } } },
                        { path = %s, status = "modified", base = %s, hunks = { { id = "m1", old_start = 1, old_lines = 1, new_start = 1, new_lines = 1, lines = { "-o1", "+O1" } } } },
                } } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		vim.inspect(del),
		vim.inspect(O),
		vim.inspect(other),
		vim.inspect(O2)
	))

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(del)))
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]),
		"accepted",
		{ fail_reason = "precondition: decided" }
	)

	child.lua_get([[require("codeforge.sidebar.actions").undo()]])

	Q.expect_lines(
		"undo restores the exact unsaved content",
		child.api.nvim_buf_get_lines(Q.find_buf(del), 0, -1, false),
		U
	)
end

T["redo re-applies atomic content from the recorded snapshot"] = function()
	local O = { "disk1", "disk2" }
	local U = { "edited1", "edited2" }
	local del = F.tmp_path()
	child.fn.writefile(O, del)
	child.cmd("edit " .. del)
	child.api.nvim_buf_set_lines(Q.find_buf(del), 0, -1, false, U)

	local O2 = { "o1", "o2" }
	local other = F.tmp_path()
	child.fn.writefile(O2, other)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { { id = "change-001", title = "T", files = {
                        { path = %s, status = "deleted", base = %s, hunks = { { id = "d1", old_start = 1, old_lines = 2, new_start = 1, new_lines = 0, lines = { "-disk1", "-disk2" } } } },
                        { path = %s, status = "modified", base = %s, hunks = { { id = "m1", old_start = 1, old_lines = 1, new_start = 1, new_lines = 1, lines = { "-o1", "+O1" } } } },
                } } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		vim.inspect(del),
		vim.inspect(O),
		vim.inspect(other),
		vim.inspect(O2)
	))

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(del)))
	child.lua_get([[require("codeforge.sidebar.actions").undo()]])
	Q.expect_lines("undo restores U", child.api.nvim_buf_get_lines(Q.find_buf(del), 0, -1, false), U)

	child.lua_get([[require("codeforge.sidebar.actions").redo()]])
	Q.expect_lines("redo re-empties the accepted deletion", child.api.nvim_buf_get_lines(Q.find_buf(del), 0, -1, false), {
		"",
	})
end

T["accepting a freshly added file keeps its previewed content"] = function()
	local path = F.tmp_path()
	local lines = { "NEW_CONTENT" }
	F.seed_added_file(path, lines)

	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(path)))
	local buf = Q.find_buf(path)
	Q.expect_lines("preview shows the new content", child.api.nvim_buf_get_lines(buf, 0, -1, false), lines)

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "deciding the only file should complete the change",
	})
	Q.expect_lines("accepted content is kept", child.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
	local entry = child.lua_get([=[require("codeforge.state").log[#require("codeforge.state").log]]=])
	MiniTest.expect.equality(entry.files[1].decision, "accepted", {
		fail_reason = "the added file should be logged as accepted",
	})
end

T["a reject sweep on a previewed added file drops its content"] = function()
	local lines = { "NEW_CONTENT" }
	local added = F.tmp_path()
	F.seed_added_file(added, lines)

	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(added)))
	local buf = Q.find_buf(added)
	Q.expect_lines("preview shows the new content", child.api.nvim_buf_get_lines(buf, 0, -1, false), lines)

	child.lua_get([[require("codeforge.sidebar.actions").reject_pending()]])

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "the reject sweep should complete the change",
	})
	Q.expect_lines("rejected added content is dropped", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "" })
	local entry = child.lua_get([=[require("codeforge.state").log[#require("codeforge.state").log]]=])
	MiniTest.expect.equality(entry.files[1].decision, "rejected", {
		fail_reason = "the added file should be logged as rejected",
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

-- ── D: gap-conflict safety (refuse to finish) ────────────────────────────

---Seed a modified file whose pre-review gap edit and during-review gap edit
---conflict, open its review, and apply the during-review edit. Returns path.
local function seed_gap_conflict()
	local O = { "a", "b", "c" }
	local U = { "USER", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, U)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })
	open_review(path)
	-- during-review edit to the gap line above the hunk
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, 1, false, { "DURING" })
	return path
end

---True when any line is a git merge-conflict marker.
local function has_conflict_markers(lines)
	for _, l in ipairs(lines) do
		local p = l:sub(1, 7)
		if p == "<<<<<<<" or p == "=======" or p == ">>>>>>>" then
			return true
		end
	end
	return false
end

T["conflicting gap edits refuse completion, keep the review, and add no markers"] = function()
	local path = seed_gap_conflict()
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(has_conflict_markers(lines), false, {
		fail_reason = "no conflict markers may be written, got " .. vim.inspect(lines),
	})
	Q.expect_lines("both snapshots and the live content are kept", lines, { "DURING", "B", "c" })
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(path))),
		true,
		{ fail_reason = "the review must be kept on a refused completion" }
	)
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 1, {
		fail_reason = "the change must stay tracked",
	})
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").log]]), 0, {
		fail_reason = "a refused completion must not log an outcome",
	})
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").completed["change-001"] == nil]]),
		true,
		{ fail_reason = "a refused completion must not record a completed change" }
	)
end

T["a gap conflict on explicit dismiss keeps the review, buffer, and save guard"] = function()
	local path = seed_gap_conflict()
	child.lua(string.format(
		[[local ok, err = require("codeforge.review.buffer").dismiss(%s); _G.__dok, _G.__derr = ok, err]],
		vim.inspect(path)
	))

	MiniTest.expect.equality(child.lua_get([[_G.__dok]]), false, {
		fail_reason = "dismiss must refuse on a gap conflict",
	})
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(path))),
		true,
		{ fail_reason = "a refused dismiss must keep the review" }
	)
	Q.expect_lines("buffer unchanged", child.api.nvim_buf_get_lines(Q.find_buf(path), 0, -1, false), {
		"DURING",
		"B",
		"c",
	})
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("buftype", { buf = Q.find_buf(path) }),
		"acwrite",
		{ fail_reason = "the save guard must remain armed after a refused dismiss" }
	)
end

T["completion succeeds once the conflicting live gap is reconciled"] = function()
	local path = seed_gap_conflict()
	-- reconcile: restore the live gap line to match the pre-review snapshot
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, 1, false, { "USER" })
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "a reconciled gap must allow completion",
	})
	Q.expect_lines("reconciled final", child.api.nvim_buf_get_lines(Q.find_buf(path), 0, -1, false), {
		"USER",
		"B",
		"c",
	})
	local log = child.lua_get([[require("codeforge.state").log]])
	MiniTest.expect.equality(log[1].status, "modified", {
		fail_reason = "the during-review hand edit derives a modified outcome, got " .. tostring(log[1].status),
	})
end

T["a later file's gap conflict does not partially dismiss an earlier file"] = function()
	local O1 = { "a1", "a2" }
	local p1 = F.tmp_path()
	child.fn.writefile(O1, p1)
	local O2 = { "a", "b", "c" }
	local U2 = { "USER", "b", "c" }
	local p2 = F.tmp_path()
	child.fn.writefile(O2, p2)
	child.cmd("edit " .. p2)
	child.api.nvim_buf_set_lines(Q.find_buf(p2), 0, -1, false, U2)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.changes = { { id = "change-001", title = "T", files = {
				{ path = %s, status = "modified", base = %s, hunks = { %s } },
				{ path = %s, status = "modified", base = %s, hunks = { %s } },
			} } }
			state.current_change_index = 1
			state.current_change_id = "change-001"
		]],
		vim.inspect(p1),
		vim.inspect(O1),
		vim.inspect(F.replace_hunk("h1", 2, "a2", "A2")),
		vim.inspect(p2),
		vim.inspect(O2),
		vim.inspect(F.replace_hunk("h2", 2, "b", "B"))
	))
	open_review(p1)
	open_review(p2)
	-- introduce the conflict in the second file only
	child.api.nvim_buf_set_lines(Q.find_buf(p2), 0, 1, false, { "DURING" })

	child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(p1))),
		true,
		{ fail_reason = "the earlier file must not be dismissed before the later conflict is found" }
	)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(p2))),
		true,
		{ fail_reason = "the conflicting file's review must be kept" }
	)
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").log]]), 0, {
		fail_reason = "no completion may be logged",
	})
	MiniTest.expect.equality(
		child.lua_get(
			string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(p2))
		),
		U2,
		{ fail_reason = "the conflicting file's snapshot must be preserved" }
	)
end

-- ── E: atomic new-round baselines ────────────────────────────────────────

T["reopening a completed added file starts a fresh atomic baseline"] = function()
	local path = F.tmp_path()
	F.seed_added_file(path, { "NEW" })
	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(path)))
	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(path)))
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "precondition: the accept completed the change",
	})

	child.lua([[require("codeforge.state").reopen_change("change-001")]])
	local buf = Q.find_buf(path)
	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(path)))
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(path))),
		{ "NEW" },
		{ fail_reason = "the new round's U is the previous final content" }
	)

	child.lua_get([[require("codeforge.sidebar.actions").reject_pending()]])
	Q.expect_lines("new round reject keeps the new U", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "NEW" })
end

T["reopen resets the atomic baseline while undo revival retains it"] = function()
	local path = F.tmp_path()
	F.seed_added_file(path, { "NEW" })
	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(path)))
	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").completed["change-001"].change.files[1].atomic_baseline ~= nil]]),
		true,
		{ fail_reason = "the first decision must capture a baseline" }
	)

	-- undo revival is not a new round: the baseline survives
	child.lua_get([[require("codeforge.sidebar.actions").undo()]])
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].atomic_baseline ~= nil]]),
		true,
		{ fail_reason = "undo revival must retain the atomic baseline" }
	)
	child.lua_get([[require("codeforge.sidebar.actions").redo()]])

	-- reopen is a new round: the baseline resets
	child.lua([[require("codeforge.state").reopen_change("change-001")]])
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].atomic_baseline == nil]]),
		true,
		{ fail_reason = "reopen must reset the atomic baseline for the new round" }
	)
end

return T
