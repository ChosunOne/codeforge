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

---True if `details` is a valid modified-line highlight: CodeForgeHunkModified
---hl + sign, with a '~' sign text.
local function is_modified_highlight(details)
	return details ~= nil
		and details.hl_group == "CodeForgeHunkModified"
		and details.sign_hl_group == "CodeForgeHunkModified"
		and details.sign_text == "~ "
end

local function is_added_highlight(details)
	return details ~= nil
		and details.hl_group == "CodeForgeHunkAdded"
		and details.sign_hl_group == "CodeForgeHunkAdded"
		and details.sign_text == "+ "
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

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
end

T["a 1->1 modify renders the new line as Modified, not a removal fold"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-mod", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })

	MiniTest.expect.equality(
		is_modified_highlight(Q.hl_at(buf, n, 1)),
		true,
		{ fail_reason = "row 1 should be a Modified highlight (~ sign, CodeForgeHunkModified)" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 1)),
		false,
		{ fail_reason = "a modified line should not carry the Added highlight/sign" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "a modify hunk must not render a 'N lines removed' fold" }
	)
	MiniTest.expect.equality(Q.hl_at(buf, n, 0) == nil, true, { fail_reason = "context row 0 decorated" })
	MiniTest.expect.equality(Q.hl_at(buf, n, 2) == nil, true, { fail_reason = "context row 2 decorated" })
end

T["a multi-line modify classifies lines: modified, context, added"] = function()
	local O = { "a", "x", "y", "b" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = {
		id = "hunk-multi",
		old_start = 2,
		old_lines = 2,
		new_start = 2,
		new_lines = 3,
		lines = { "-x", "-y", "+X", "+y", "+Z" },
		status = "modified",
	}
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "X", "y", "Z", "b" })

	MiniTest.expect.equality(
		is_modified_highlight(Q.hl_at(buf, n, 1)),
		true,
		{ fail_reason = "row 1 'X' should be Modified (was 'x')" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 2) == nil,
		true,
		{ fail_reason = "row 2 'y' is unchanged context, should have no highlight" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 3)),
		true,
		{ fail_reason = "row 3 'Z' should be Added" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "modify hunk must not render a removal fold" }
	)
end

T["a modify that re-indents a line treats it as context, new lines as added"] = function()
	local O = { "a", "  dial" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = {
		id = "hunk-reindent",
		old_start = 2,
		old_lines = 1,
		new_start = 2,
		new_lines = 3,
		lines = { "-  dial", "+  for attempt = 1, 3 do", "+    dial", "+  end" },
		status = "modified",
	}
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines(
		"P",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "  for attempt = 1, 3 do", "    dial", "  end" }
	)

	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 1)),
		true,
		{ fail_reason = "row 1 'for ...' should be Added" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 2) == nil,
		true,
		{ fail_reason = "row 2 'dial' (re-indented) is context, no highlight" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 3)),
		true,
		{ fail_reason = "row 3 'end' should be Added" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "re-indent modify must not render a removal fold" }
	)
end

return T
