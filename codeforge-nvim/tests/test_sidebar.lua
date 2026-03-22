local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 80
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
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["sidebar opens on right side"] = function()
	child.cmd("CodeForge")

	local wins = child.api.nvim_list_wins()

	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

return T
