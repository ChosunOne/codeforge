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

local function buf_lines(path)
	return child.api.nvim_buf_get_lines(Q.find_buf(path), 0, -1, false)
end

local function hunk_status(path, hunk_id)
	return F.hunk_outcome(path, hunk_id)
end

local function undo()
	return child.lua_get([[require("codeforge.sidebar.actions").undo()]])
end

local function redo()
	return child.lua_get([[require("codeforge.sidebar.actions").redo()]])
end

local function ns()
	return child.lua_get([[require("codeforge.review.diff").namespace]])
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

T["undo reverses a reject: status, buffer, and decorations"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	local buf = open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):reject_hunk(1)]], vim.inspect(path)))
	Q.expect_lines("after reject", buf_lines(path), { "a", "b", "c", "D", "e" })

	MiniTest.expect.equality(undo(), 1, { fail_reason = "one record undone" })

	MiniTest.expect.equality(hunk_status(path, "h1"), vim.NIL, {
		fail_reason = "h1 should be pending again, got " .. vim.inspect(hunk_status(path, "h1")),
	})
	Q.expect_lines("after undo", buf_lines(path), { "a", "B", "c", "D", "e" })
	-- the proposal sign/highlight must be back on the restored region
	MiniTest.expect.equality(Q.hl_at(buf, ns(), 1) ~= nil, true, {
		fail_reason = "h1's modified highlight should be re-rendered after undo",
	})

	MiniTest.expect.equality(redo(), 1, { fail_reason = "one record redone" })
	MiniTest.expect.equality(hunk_status(path, "h1"), "rejected", { fail_reason = "redo re-rejects" })
	Q.expect_lines("after redo", buf_lines(path), { "a", "b", "c", "D", "e" })
end

T["undo reverts to the exact pre-action buffer (whole-buffer semantics)"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	-- user edit outside the hunks, pre-review (lives in U, not the review buffer)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, 1, false, { "a-user" })
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))
	-- hand-edit the accepted region afterwards (intervening edit)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 1, 2, false, { "B-edit" })

	undo()

	MiniTest.expect.equality(hunk_status(path, "h1"), vim.NIL, { fail_reason = "h1 pending after undo" })
	-- pre-action buffer was P; the intervening hand-edit reverts with it
	-- (editor-undo semantics; redo would bring it back)
	Q.expect_lines("undo reverts to pre-accept buffer", buf_lines(path), { "a", "B", "c", "D", "e" })
	MiniTest.expect.equality(hunk_status(path, "h2"), vim.NIL, {
		fail_reason = "h2 was never triaged in this test",
	})
end

T["undo on an accepted delete hunk restores the fold"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.delete_hunk("h1", 2, { "b" })
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	local n = ns()
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(0)]], vim.inspect(path)))
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "fold should be gone while the deletion is confirmed" }
	)

	undo()

	MiniTest.expect.equality(hunk_status(path, "h1"), vim.NIL, { fail_reason = "h1 pending after undo" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "the deletion fold must be restored by undo" }
	)
end

T["undoing a decision flip restores the file decision"] = function()
	local added = F.tmp_path()
	child.fn.writefile({ "new" }, added)
	local O = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(O, pa)
	child.lua(
		string.format(
			[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "T",
                        files = {
                                { path = %s, status = "added", hunks = {} },
                                { path = %s, status = "modified", base = %s, hunks = { %s } },
                        },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
			vim.inspect(added),
			vim.inspect(pa),
			vim.inspect(O),
			vim.inspect(F.replace_hunk("a-h1", 2, "a2", "A2"))
		)
	)

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(added)))
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]),
		"accepted",
		{ fail_reason = "precondition: decided" }
	)

	undo()

	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]),
		vim.NIL,
		{ fail_reason = "decision should be undecided after undo" }
	)

	redo()

	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]),
		"accepted",
		{ fail_reason = "redo re-applies the decision" }
	)
end

T["redo is invalidated by a new action"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })
	open_review(path)
	local review_cmd = string.format([[local r = require("codeforge.state").get_review(%s); ]], vim.inspect(path))

	child.lua(review_cmd .. [[r:accept_hunk(1)]])
	undo()
	child.lua(review_cmd .. [[r:accept_hunk(3)]]) -- new action after undo

	MiniTest.expect.equality(redo(), 0, { fail_reason = "redo stack must be empty after a new action" })
end

T["undo and redo on empty stacks are no-ops"] = function()
	MiniTest.expect.equality(undo(), 0, { fail_reason = "undo with no history" })
	MiniTest.expect.equality(redo(), 0, { fail_reason = "redo with no history" })
end

T["undo/redo keybinds work from the review buffer"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	local buf = open_review(path)
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>u"), true, { fail_reason = "no undo keymap" })
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>R"), true, { fail_reason = "no redo keymap" })

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>u")
	child.lua([[vim.wait(100)]])

	MiniTest.expect.equality(hunk_status(path, "h1"), vim.NIL, {
		fail_reason = "<C-x>u should undo the accept from the review buffer",
	})
end

return T
