local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
		end,
		post_once = child.stop,
	},
})

T["plugin loads without error"] = function()
	child.lua([[require('codeforge').setup()]])
	local config = child.lua_get([[require('codeforge').config]])
	MiniTest.expect.equality(type(config), "table")
end

return T
