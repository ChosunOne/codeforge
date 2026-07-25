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

local function virt_text(details)
	if not details or not details.virt_lines then
		return ""
	end
	local out = {}
	for _, vline in ipairs(details.virt_lines) do
		for _, chunk in ipairs(vline) do
			out[#out + 1] = chunk[1] or ""
		end
	end
	return table.concat(out)
end

local function fold_says(details, text)
	if not details or not details.virt_lines then
		return false
	end
	local has_text = virt_text(details):find(text, 1, true) ~= nil
	local has_hl = false
	for _, vline in ipairs(details.virt_lines) do
		for _, chunk in ipairs(vline) do
			if chunk[2] == "CodeForgeHunkDeleted" then
				has_hl = true
			end
		end
	end
	return has_text and has_hl
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

T["added lines render with a DiffAdd highlight and a sign"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.insert_hunk("hunk-add", 2, { "B" })
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "review buffer missing" })
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "b", "c" })

	local n = ns()
	local hl = Q.hl_at(buf, n, 1)
	MiniTest.expect.equality(
		is_added_highlight(hl),
		true,
		{ fail_reason = "no valid CodeForgeHunkAdded highlight + sign on added line (row 1)" }
	)
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 0, 0), 0, { fail_reason = "context line 0 decorated" })
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 2, 0), 0, { fail_reason = "context line 2 decorated" })
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 3, 0), 0, { fail_reason = "context line 3 decorated" })

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["a hunk that adds and deletes renders both a fold and a highlight"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-both", 2, "b", "B", "B2")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "B2", "c", "d" })

	local fold = Q.fold_at(buf, n, 0)
	MiniTest.expect.equality(
		fold_says(fold, "1 line removed"),
		true,
		{ fail_reason = "no valid deletion fold at row 0" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 1)),
		true,
		{ fail_reason = "no valid added-line hightlight at row 1" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 2)),
		true,
		{ fail_reason = "no valid added-line hightlight at row 2" }
	)

	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 3, 0), 0, { fail_reason = "context line 3 decorated" })
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 4, 0), 0, { fail_reason = "context line 4 decorated" })

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["deleted lines render as a collapsed virtual fold"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.delete_hunk("hunk-del", 2, { "b", "c", "d" })
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "e" })

	local fold = Q.fold_at(buf, n, 0)
	MiniTest.expect.equality(
		fold_says(fold, "3 lines removed"),
		true,
		{ fail_reason = "no valid deletion fold at row 0" }
	)

	for _, line in ipairs(child.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		MiniTest.expect.equality(
			line ~= "b" and line ~= "c" and line ~= "d",
			true,
			{ fail_reason = "deleted line leaked into buffer text: " .. line }
		)
	end

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["deletion fold is collapsed by default"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.delete_hunk("hunk-del", 2, { "b" })
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	local n = ns()
	local fold = Q.fold_at(buf, n, 0)
	MiniTest.expect.equality(fold ~= nil, true, { fail_reason = "no deletion fold rendered" })
	MiniTest.expect.equality(
		virt_text(fold):find("b", 1, true) == nil,
		true,
		{ fail_reason = "deleted text 'b' shown in collapsed fold" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["inserted lines render as added lines with highlight"] = function()
	local O = { "a", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.insert_hunk("hunk-ins", 2, { "b1", "b2" })
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b1", "b2", "c" })

	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 1)),
		true,
		{ fail_reason = "no valid added-line highlight at row 1" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 2)),
		true,
		{ fail_reason = "no valid added-line highlight at row 2" }
	)
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 0, 0), 0, { fail_reason = "context line 0 decorated" })
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 3, 0), 0, { fail_reason = "context line 3 decorated" })

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["two separate hunks each render their own artifacts"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("hunk-one", 2, "b", "B")
	local h2 = F.replace_hunk("hunk-two", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c", "D", "e" })

	MiniTest.expect.equality(
		fold_says(Q.fold_at(buf, n, 0), "1 line removed"),
		true,
		{ fail_reason = "no valid deletion fold for hunk-one at row 0" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 1)),
		true,
		{ fail_reason = "no valid added-line highlight for hunk-one at row 1" }
	)
	MiniTest.expect.equality(
		fold_says(Q.fold_at(buf, n, 2), "1 line removed"),
		true,
		{ fail_reason = "no valid deletion fold for hunk-one at row 2" }
	)
	MiniTest.expect.equality(
		is_added_highlight(Q.hl_at(buf, n, 3)),
		true,
		{ fail_reason = "no valid added-line highlight for hunk-one at row 3" }
	)
	MiniTest.expect.equality(#Q.extmarks_at(buf, n, 4, 0), 0, { fail_reason = "context line 4 decorated" })

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["deletion at the last line of the file renders a fold"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.delete_hunk("hunk-del-end", 3, { "c" })
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path) ---@type integer
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b" })
	local fold = Q.fold_at(buf, n, 1)
	MiniTest.expect.equality(
		fold_says(fold, "1 line removed"),
		true,
		{ fail_reason = "no valid deletion fold for end of file deletion at row 1" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

return T
