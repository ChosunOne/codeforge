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

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
end

---The cursor row (0-indexed) of the focused window.
local function cursor_row()
	return child.api.nvim_win_get_cursor(0)[1] - 1
end

---Focus the review window and return it.
local function focus_review(buf)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	return win
end

T["next_hunk jumps to the next pending hunk and wraps around"] = function()
	local O = { "a", "b", "c", "d", "e", "f", "g" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	local h3 = F.replace_hunk("h3", 6, "f", "F")
	F.seed_change(path, O, { h1, h2, h3 })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c", "D", "e", "F", "g" })

	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>n"), true, { fail_reason = "no <C-x>n (next hunk) keymap" })
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>b"), true, { fail_reason = "no <C-x>b (prev hunk) keymap" })

	local win = focus_review(buf)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	MiniTest.expect.equality(cursor_row() == 1, true, { fail_reason = "precondition: on h1" })

	child.type_keys("<C-x>n")
	MiniTest.expect.equality(cursor_row() == 2, true, { fail_reason = "<C-x>n from h1 should land on h2 (row 2)" })

	child.type_keys("<C-x>n")
	MiniTest.expect.equality(cursor_row() == 4, true, { fail_reason = "<C-x>n from h2 should land on h3 (row 4)" })

	child.type_keys("<C-x>n")
	MiniTest.expect.equality(cursor_row() == 0, true, { fail_reason = "<C-x>n from h3 should wrap to h1 (row 0)" })
end

T["prev_hunk jumps to the previous pending hunk and wraps around"] = function()
	local O = { "a", "b", "c", "d", "e", "f", "g" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	local h3 = F.replace_hunk("h3", 6, "f", "F")
	F.seed_change(path, O, { h1, h2, h3 })

	local buf = open_review(path)
	local win = focus_review(buf)
	child.api.nvim_win_set_cursor(win, { 6, 0 })

	child.type_keys("<C-x>b")
	MiniTest.expect.equality(cursor_row() == 2, true, { fail_reason = "<C-x>b from h3 should land on h2 (row 2)" })

	child.type_keys("<C-x>b")
	MiniTest.expect.equality(cursor_row() == 0, true, { fail_reason = "<C-x>b from h2 should land on h1 (row 0)" })

	child.type_keys("<C-x>b")
	MiniTest.expect.equality(cursor_row() == 4, true, { fail_reason = "<C-x>b from h1 should wrap to h3 (row 4)" })
end

T["hunk navigation skips accepted and rejected hunks"] = function()
	local O = { "a", "b", "c", "d", "e", "f", "g" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	local h3 = F.replace_hunk("h3", 6, "f", "F")
	F.seed_change(path, O, { h1, h2, h3 })

	local buf = open_review(path)
	local win = focus_review(buf)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	child.api.nvim_win_set_cursor(win, { 3, 0 }) -- h2 add moved; land near it
	child.type_keys("<C-x>j")

	child.api.nvim_win_set_cursor(win, { 1, 0 })
	child.type_keys("<C-x>n")
	MiniTest.expect.equality(
		cursor_row() == 4,
		true,
		{ fail_reason = "<C-x>n should skip accepted h1 & rejected h2, landing on h3 (row 4)" }
	)

	child.type_keys("<C-x>n")
	MiniTest.expect.equality(
		cursor_row() == 4,
		true,
		{ fail_reason = "with only h3 pending, <C-x>n should stay/wrap to h3 (row 4)" }
	)
end

return T
