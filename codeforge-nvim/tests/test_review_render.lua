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

local function focus_buf(buf)
	for _, w in ipairs(child.api.nvim_list_wins()) do
		if child.api.nvim_win_get_buf(w) == buf then
			child.api.nvim_set_current_win(w)
			return
		end
	end
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

T["added lines render with a DiffAd highlight and a sign"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-add", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "review buffer missing" })
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })

	local n = ns()
	local ok, _id, row = Q.has_hl_group(buf, n, "CodeForgeHunkAdded")
	MiniTest.expect.equality(ok, true, { fail_reason = "no CodeForgeHunkAdded highlight on added line" })
	MiniTest.expect.equality(row, 1, { fail_reason = "added-line highlight on wrong row: " .. tostring(row) })

	MiniTest.expect.equality(Q.has_sign(buf, n, "CodeForgeHunkAdded"), true, { fail_reason = "no sign on added line" })

	focus_buf(buf)
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

	local buf = Q.find_buf(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "e" })

	MiniTest.expect.equality(
		Q.has_virt_line_containing(buf, n, "3 lines removed"),
		true,
		{ fail_reason = "no '3 lines removed' vitual fold line" }
	)

	for _, line in ipairs(child.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		MiniTest.expect.equality(
			line ~= "b" and line ~= "c" and line ~= "d",
			true,
			{ fail_reason = "deleted line leaked into buffer text: " .. line }
		)
	end

	focus_buf(buf)
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

	local buf = Q.find_buf(path)
	local n = ns()
	local fold_seen = false
	for _, m in ipairs(Q.extmarks(buf, n)) do
		local d = m[4]
		if d and d.virt_lines then
			fold_seen = true
			for _, vline in ipairs(d.virt_lines) do
				for _, chunk in ipairs(vline) do
					MiniTest.expect.equality(
						(chunk[1] or ""):find("b", 1, true) == nil,
						true,
						{ fail_reason = "deleted text 'b' shown in fold virtual line" }
					)
				end
			end
		end
	end

	MiniTest.expect.equality(fold_seen, true, { fail_reason = "no deletion fold rendered" })

	focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["each hunk has a named extmark covering its line range"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)

	local h1 = F.replace_hunk("hunk-one", 2, "b", "B")
	local h2 = F.replace_hunk("hunk-two", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	local n = ns()

	local r1_s, r1_e = Q.find_extmark_by_id(buf, n, "hunk-one")
	MiniTest.expect.equality(r1_s ~= nil, true, { fail_reason = "no extmark for hunk-one" })
	local r2_s, r2_e = Q.find_extmark_by_id(buf, n, "hunk-two")
	MiniTest.expect.equality(r2_s ~= nil, true, { fail_reason = "no extmark for hunk-two" })

	MiniTest.expect.equality(
		r1_s <= 2 and r1_e >= 2,
		true,
		{ fail_reason = "hunk-one extmark does not cover line 2: " .. r1_s .. ".." .. r1_e }
	)
	MiniTest.expect.equality(
		r2_s <= 4 and r2_e >= 4,
		true,
		{ fail_reason = "hunk-two extmark does not cover line 4: " .. r2_s .. ".." .. r2_e }
	)

	MiniTest.expect.equality(r1_s ~= r2_s or r1_e ~= r2_e, true, { fail_reason = "hunk extmarks overlap identically" })

	focus_buf(buf)
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

	local buf = Q.find_buf(path)
	local n = ns()

	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b1", "b2", "c" })

	local count = 0
	for _, m in ipairs(Q.extmarks(buf, n)) do
		local d = m[4]
		if d and d.hl_group == "CodeForgeHunkAdded" then
			count = count + 1
		end
	end
	MiniTest.expect.equality(count >= 2, true, { fail_reason = "expected >2 added-line highlights, got " .. count })

	focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["screenshot of a mixed add/delete review buffer"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.delete_hunk("hunk-del", 2, { "b", "c" })
	local h2 = F.replace_hunk("hunk-rep", 5, "e", "E")
	F.seed_change(path, O, { h1, h2 })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

return T
