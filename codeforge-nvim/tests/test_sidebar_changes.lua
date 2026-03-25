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

T["sidebar shows change header with count"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.changes = {
			{
				id = "change-001",
				title = "Add authentication middleware",
				timestamp = 1700000000,
				status = "pending",
				files = {}
			},
			{
				id = "change-002",
				title = "Fix logging bug",
				timestamp = 1700000100,
				status = "pending",
				files = {}
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

	MiniTest.expect.equality(string.find(lines[1], "%[1/2%]") ~= nil, true)

	MiniTest.expect.equality(string.find(lines[1], "Add authentication middleware") ~= nil, true)

	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["Navigates to next change"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.changes = {
			{
				id = "change-001",
				title = "Add authentication middleware",
				timestamp = 1700000000,
				status = "pending",
				files = {}
			},
			{
				id = "change-002",
				title = "Fix logging bug",
				timestamp = 1700000100,
				status = "pending",
				files = {}
			}
		}

		state.current_change_index = 1
		state.current_change_id = "change-001"
	]])

	child.cmd("CodeForge")

	child.type_keys("<C-]>")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)

	local current_index = child.lua_get([[require("codeforge.state").current_change_index]])
	MiniTest.expect.equality(current_index, 2, { fail_reason = "Got " .. current_index })

	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(
		string.find(lines[1], "%[2/2%] Fix logging bug") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[1] }
	)

	local current_id = child.lua_get([[require("codeforge.state").current_change_id]])
	MiniTest.expect.equality(current_id, "change-002")
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["Navigates to previous change"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.changes = {
			{
				id = "change-001",
				title = "Add authentication middleware",
				timestamp = 1700000000,
				status = "pending",
				files = {}
			},
			{
				id = "change-002",
				title = "Fix logging bug",
				timestamp = 1700000100,
				status = "pending",
				files = {}
			}
		}

		state.current_change_index = 2
		state.current_change_id = "change-002"
	]])
	child.cmd("CodeForge")

	child.type_keys("<C-[>")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)

	local current_index = child.lua_get([[require("codeforge.state").current_change_index]])
	MiniTest.expect.equality(current_index, 1, { fail_reason = "Got " .. current_index })

	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(
		string.find(lines[1], "%[1/2%] Add authentication middleware") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[1] }
	)

	local current_id = child.lua_get([[require("codeforge.state").current_change_id]])
	MiniTest.expect.equality(current_id, "change-001")
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["Navigates to next change (wraparound)"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.changes = {
			{
				id = "change-001",
				title = "Add authentication middleware",
				timestamp = 1700000000,
				status = "pending",
				files = {}
			},
			{
				id = "change-002",
				title = "Fix logging bug",
				timestamp = 1700000100,
				status = "pending",
				files = {}
			}
		}

		state.current_change_index = 2
		state.current_change_id = "change-002"
	]])
	child.cmd("CodeForge")

	child.type_keys("<C-]>")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)

	local current_index = child.lua_get([[require("codeforge.state").current_change_index]])
	MiniTest.expect.equality(current_index, 1, { fail_reason = "Got " .. current_index })

	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(
		string.find(lines[1], "%[1/2%] Add authentication middleware") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[1] }
	)

	local current_id = child.lua_get([[require("codeforge.state").current_change_id]])
	MiniTest.expect.equality(current_id, "change-001")
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["Navigates to previous change (wraparound)"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.changes = {
			{
				id = "change-001",
				title = "Add authentication middleware",
				timestamp = 1700000000,
				status = "pending",
				files = {}
			},
			{
				id = "change-002",
				title = "Fix logging bug",
				timestamp = 1700000100,
				status = "pending",
				files = {}
			}
		}

		state.current_change_index = 1
		state.current_change_id = "change-001"
	]])

	child.cmd("CodeForge")

	child.type_keys("<C-[>")

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)

	local current_index = child.lua_get([[require("codeforge.state").current_change_index]])
	MiniTest.expect.equality(current_index, 2, { fail_reason = "Got " .. current_index })

	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(
		string.find(lines[1], "%[2/2%] Fix logging bug") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[1] }
	)

	local current_id = child.lua_get([[require("codeforge.state").current_change_id]])
	MiniTest.expect.equality(current_id, "change-002")
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

return T
