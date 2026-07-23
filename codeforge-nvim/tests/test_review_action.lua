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

local function ns()
	return child.lua_get([[require("codeforge.review.diff").namespace]])
end

local function hunk_status(path, hunk_id)
	return child.lua_get(
		string.format(
			[=[((require("codeforge.state").get_review(%s) or {}).hunk_status or {})[%s]]=],
			vim.inspect(path),
			vim.inspect(hunk_id)
		)
	)
end

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
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

T["reject on a pure-insert hunk removes the added lines and marks it rejected"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.insert_hunk("hunk-ins", 2, { "B" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "b", "c" })

	MiniTest.expect.equality(
		F.has_keymap(buf, "<C-x>j"),
		true,
		{ fail_reason = "no <C-x>j keymap on the review buffer" }
	)

	local win = Q.win_for_buf(buf)
	MiniTest.expect.equality(win ~= nil, true, { fail_reason = "review buffer not shown in a window" })
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- 1-indexed row 2 == 0-indexed row 1

	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "add highlight should be on row 1 before reject" }
	)

	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-ins") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "add highlight should be removed after reject" }
	)
end

T["reject on a replace hunk restores the original line and marks it rejected"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-rep", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "deletion fold should be on row 0 before reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "add highlight should be on row 1 before reject" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "B"
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-rep") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "deletion fold should be removed after reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "add highlight should be removed after reject" }
	)
end

T["reject on a delete-only hunk restores the removed lines"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.delete_hunk("hunk-del", 2, { "b" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "c" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "deletion fold should be on row 0 before reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "row 1 should not carry an add highlight (delete-only hunk)" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 1, 0 }) -- row 0, the fold anchor "a"
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-del") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "deletion fold should be removed after reject" }
	)
end

T["reject restores the user's pre-review edits (U), not the base (O)"] = function()
	local O = { "a", "b", "c" }
	local U = { "a", "b-user", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-rep", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "B"
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject (U, not O)", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b-user", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-rep") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
end

T["reject with coordinate drift restores the right U lines"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local U = { "a", "USER", "b", "c-USER", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-drift", 3, "c", "C")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "C", "d", "e" })

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 3, 0 }) -- row 2, the added line "C"
	child.type_keys("<C-x>j")

	Q.expect_lines(
		"after reject (drifted + edited U)",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "b", "c-USER", "d", "e" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-drift") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
end

T["accept merges U's region edits with the proposal (clean 3-way)"] = function()
	local O = { "a", "p", "m", "q", "d" }
	local U = { "a", "p", "m", "Q", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = {
		id = "hunk-acc",
		old_start = 2,
		old_lines = 3,
		new_start = 2,
		new_lines = 3,
		lines = { "-p", "-m", "-q", "+P", "+m", "+q" },
	}
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "P", "m", "q", "d" })

	MiniTest.expect.equality(
		F.has_keymap(buf, "<C-x>a"),
		true,
		{ fail_reason = "no <C-x>a keymap on the review buffer" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "P"
	child.type_keys("<C-x>a")

	Q.expect_lines(
		"after accept (combined U+P)",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "P", "m", "Q", "d" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-acc") == "accepted",
		true,
		{ fail_reason = "hunk should be marked 'accepted'" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "deletion fold should be removed after accept" }
	)
end

return T
