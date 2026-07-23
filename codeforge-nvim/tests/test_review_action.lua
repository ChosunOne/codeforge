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

return T
