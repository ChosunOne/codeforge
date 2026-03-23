local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
		end,
		post_once = child.stop,
	},
})

T["CodeForge command opens sidebar"] = function()
	local wins_before = #child.api.nvim_list_wins()

	child.cmd("CodeForge")

	local wins_after = #child.api.nvim_list_wins()

	MiniTest.expect.equality(wins_after > wins_before, true)

	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["sidebar shows codeforge title"] = function()
	child.cmd("CodeForge")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)
	local ft = child.api.nvim_buf_get_option(buf, "filetype")

	MiniTest.expect.equality(ft, "codeforge")

	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)

	MiniTest.expect.equality(lines[1], "CodeForge - Pending Review Panel")
	MiniTest.expect.equality(lines[3], "No pending changes")

	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["sidebar opens on right side"] = function()
	child.cmd("CodeForge")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = nil
	for _, win in ipairs(wins) do
		local buf = child.api.nvim_win_get_buf(win)
		local ft = child.api.nvim_buf_get_option(buf, "filetype")
		if ft == "codeforge" then
			sidebar_win = win
			break
		end
	end

	MiniTest.expect.equality(sidebar_win ~= nil, true)

	local pos = child.api.nvim_win_get_position(sidebar_win)
	local col = pos[2]

	local editor_width = child.o.columns
	MiniTest.expect.equality(col > (editor_width / 2), true)
	local expected_col = editor_width - 40
	MiniTest.expect.equality(col, expected_col)

	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

return T
