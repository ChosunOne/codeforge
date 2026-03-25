local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_once = child.stop,
	},
})

T["sidebar displays files in change"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.changes = {
			{
				id = "change-001",
				title = "Add authentication system",
				files = {
					{ path = "src/auth.lua", status = "modified", hunks = {} },
					{ path = "src/middleware.lua", status = "added", hunks = {} },
					{ path = "tests/auth_test.lua", status = "added", hunks = {} },
					{ path = "src/old_auth.lua", status = "deleted", hunks = {} }
				}
			}
		}

		state.current_change_index = 1
		state.current_change_id = "change-001"
	]])

	child.cmd("CodeForge")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)
	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)

	MiniTest.expect.equality(string.find(lines[1], "%[1/1%] Add authentication system") ~= nil, true, {
		fail_reason = "Got " .. lines[1],
	})

	MiniTest.expect.equality(string.find(lines[3], "▸ src/auth.lua %[M%]") ~= nil, true, {
		fail_reason = "Got " .. lines[3],
	})

	MiniTest.expect.equality(string.find(lines[4], "^  src/middleware.lua %[A%]$") ~= nil, true, {
		fail_reason = "Got " .. lines[4],
	})

	MiniTest.expect.equality(string.find(lines[4], "[▸▾]") == nil, true, { fail_reason = "Got " .. lines[4] })

	MiniTest.expect.equality(
		string.find(lines[5], "^  tests/auth_test.lua %[A%]$") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[5] }
	)
	MiniTest.expect.equality(string.find(lines[5], "[▸▾]") == nil, true, { fail_reason = "Got " .. lines[5] })

	MiniTest.expect.equality(
		string.find(lines[6], "^  src/old_auth.lua %[D%]$") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[6] }
	)

	MiniTest.expect.equality(string.find(lines[6], "[▸▾]") == nil, true, { fail_reason = "Got " .. lines[6] })

	MiniTest.expect.equality(#lines, 7, { fail_reason = "Should have exactly 7 lines" })
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

return T
