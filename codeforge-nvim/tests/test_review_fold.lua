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

---True if the extmark `details` show a virt line whose joined text
---equals `text` and which is styled with `CodeForgeHunkDeleted`.
local function virt_line_is(details, text)
	if not details or not details.virt_lines then
		return false
	end
	for _, vline in ipairs(details.virt_lines) do
		local joined = ""
		local has_hl = false
		for _, chunk in ipairs(vline) do
			joined = joined .. (chunk[1] or "")
			if chunk[2] == "CodeForgeHunkDeleted" then
				has_hl = true
			end
		end

		if joined == text and has_hl then
			return true
		end
	end
	return false
end

---True if the extmark `details` show a virt line whose joined text
---contains `needle`
local function virt_line_has(details, needle)
	if not details or not details.virt_lines then
		return false
	end
	for _, vline in ipairs(details.virt_lines) do
		local joined = ""
		local has_hl = false
		for _, chunk in ipairs(vline) do
			joined = joined .. (chunk[1] or "")
			if chunk[2] == "CodeForgeHunkDeleted" then
				has_hl = true
			end
		end

		if joined:find(needle, 1, true) and has_hl then
			return true
		end
	end
	return false
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
	local buf = Q.find_buf(path)
	return buf
end

local function toggle_fold(path, row)
	child.lua(string.format(
		[[
			local r = require("codeforge.state").get_review(%s); r:toggle_fold(%d)
		]],
		vim.inspect(path),
		row
	))
end

T["toggle_fold expands a collapsed deletion fold to show the deleted lines"] = function()
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
		virt_line_has(Q.fold_at(buf, n, 0), "1 line removed"),
		true,
		{ fail_reason = "fold should start collapsed showing the hint" }
	)

	toggle_fold(path, 0)

	MiniTest.expect.equality(
		virt_line_is(Q.fold_at(buf, n, 0), "b"),
		true,
		{ fail_reason = "expanded fold should show deleted line 'b' with CodeForgeHunkDeleted" }
	)
	MiniTest.expect.equality(
		virt_line_has(Q.fold_at(buf, n, 0), "line removed"),
		false,
		{ fail_reason = "expanded fold should no longer show the 'N line(s) removed' hint" }
	)
end

T["pressing <C-x>t on a fold anchor expands the fold"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.delete_hunk("hunk-del", 2, { "b" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "c" })

	local maps = child.api.nvim_buf_get_keymap(buf, "n")
	local found = false
	for _, m in ipairs(maps) do
		if m.lhs:lower() == ("<C-x>t"):lower() then
			found = true
			break
		end
	end

	MiniTest.expect.equality(
		virt_line_has(Q.fold_at(buf, n, 0), "1 line removed"),
		true,
		{ fail_reason = "fold should start collapsed" }
	)
	if found then
		child.type_keys("<C-x>t")
		MiniTest.expect.equality(
			virt_line_is(Q.fold_at(buf, n, 0), "b"),
			true,
			{ fail_reason = "<C-x>t should expand the fold to show deleted line 'b'" }
		)
		MiniTest.expect.equality(
			virt_line_has(Q.fold_at(buf, n, 0), "line removed"),
			false,
			{ fail_reason = "<C-x>t should remove the collapsed hint" }
		)
	end
end

T["pressing <C-x>r restores the deleted lines to real buffer text"] = function()
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
		F.has_keymap(buf, "<C-x>r"),
		true,
		{ fail_reason = "no <C-x>r keymap on the review buffer" }
	)

	local win = Q.win_for_buf(buf)
	MiniTest.expect.equality(win ~= nil, true, { fail_reason = "review buffer not shown in a window" })
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 1, 0 }) -- row 1 == 0-indexed row 0

	MiniTest.expect.equality(
		virt_line_has(Q.fold_at(buf, n, 0), "1 line removed"),
		true,
		{ fail_reason = "fold should be present before restore " }
	)

	child.type_keys("<C-x>r")

	Q.expect_lines("restored P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "fold extmark should be removed after restore" }
	)
end

T["restore shifts later add highlights to keep them on the right line"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.delete_hunk("hunk-del", 2, { "b" })
	local h2 = F.insert_hunk("hink-add", 5, { "X" })
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "c", "d", "X", "e" })
	local add_before = Q.hl_at(buf, n, 3)
	MiniTest.expect.equality(
		add_before ~= nil and add_before.hl_group == "CodeForgeHunkAdded",
		true,
		{ fail_reason = "add highlight should be on row 3 ('X') before restore" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 1, 0 })
	child.type_keys("<C-x>r")

	Q.expect_lines("restored P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c", "d", "X", "e" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "fold extmark should be removed after restore" }
	)

	local add_after = Q.hl_at(buf, n, 4)
	MiniTest.expect.equality(
		add_after ~= nil and add_after.hl_group == "CodeForgeHunkAdded",
		true,
		{ fail_reason = "add highlight should have shifted to row 4 ('X') after restore" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 3) == nil,
		true,
		{ fail_reason = "row 3 should no longer carry an add highlight after restore" }
	)
end

return T
