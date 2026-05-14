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

local function setup_preview_state()
	child.lua([[
		local state = require("codeforge.state")
		local fixture_dir = vim.fn.fnamemodify("tests/fixtures", ":p")
		state.changes = {
			{
				id = "change-preview",
				title = "Preview test change",
				files = {
					{
						path = fixture_dir .. "/preview_base.lua",
						status = "modified",
						hunks = {
							{
								id = "hunk-add-greet",
								description = "Add greet function with name param",
								old_start = 1,
								old_lines = 3,
								new_start = 1,
								new_lines = 4,
								lines = {
									"local M = {}",
									"",
									"+function M.greet(name)",
									"+\treturn \"Hello, \" .. name",
									"+end",
									"",
									"function M.farewell(name)",
									"\treturn \"Goodbye, \" .. name",
									"end",
									"",
									"return M",
								},
								status = "modified",
								modified_content = nil,
							},
							{
								id = "hunk-remove-old",
								description = "Remove deprecated old_func",
								old_start = 4,
								old_lines = 3,
								new_start = 5, 
								new_lines = 0,
								lines = {
									"-function M.old_func()",
									"-\treturn \"deprecated\"",
									"-end",
								},
								status = "deleted",
								modified_content = nil,
							}
						}
					},
					{
						path = fixture_dir .. "/preview_new.lua",
						status = "added",
						hunks = {
							{
								id = "hunk-new-file",
								description = "New utility module",
								old_start = 0,
								old_lines = 0,
								new_start = 1,
								new_lines = 3,
								lines = {
									"+local M = {}",
									"+",
									"+return M",
								},
								status = "added",
								modified_content = nil,
							},
						},
					},
					{
						path = fixture_dir .. "/preview_deleted.lua",
						status = "deleted",
						hunks = {
							{
								id = "hunk-delete-file",
								description = "Delete deprecated module",
								old_start = 1,
								old_lines = 5,
								new_start = 0,
								new_lines = 0,
								lines = {
									"-local M = {}",
									"-",
									"-function M.old_func()",
									"-\treturn \"deprecated\"",
									"-end",
									"-",
									"-return M",
								},
								status = "deleted",
								modified_content = nil,
							},
						},
					},
				}
			}
		}
		state.current_change_index = 1
		state.current_change_id = "change-preview"
	]])
end

local function get_main_win()
	local wins = child.api.nvim_list_wins()
	for _, win in ipairs(wins) do
		local buf = child.api.nvim_win_get_buf(win)
		local name = child.api.nvim_buf_get_name(buf)
		if not name:match("CodeForge") then
			return win
		end
	end
	return nil
end

local function get_sidebar_win()
	local wins = child.api.nvim_list_wins()
	for _, win in ipairs(wins) do
		local buf = child.api.nvim_win_get_buf(win)
		local ft = child.api.nvim_buf_get_option(buf, "filetype")
		if ft == "codeforge" then
			return win
		end
	end
	return nil
end

T["CursorMoved to modified file opens preview"] = function()
	setup_preview_state()
	child.cmd("CodeForge")
	local sidebar = get_sidebar_win()
	child.api.nvim_set_current_win(sidebar)
	child.type_keys("3gg")

	local main = get_main_win()
	MiniTest.expect.equality(main ~= nil, true, { fail_reason = "Main window should exist" })
	local buf = child.api.nvim_win_get_buf(main)
	MiniTest.expect.equality(child.api.nvim_buf_get_option(buf, "buftype"), "nofile", {
		fail_reason = "Preview should be a scratch buffer",
	})
	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(#lines > 0, true, { fail_reason = "Preview should have content" })
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["Preview shows green highlights on added lines"] = function()
	setup_preview_state()
	child.cmd("CodeForge")
	local sidebar = get_sidebar_win()
	child.api.nvim_set_current_win(sidebar)
	child.type_keys("3gg")

	local buf = child.api.nvim_win_get_buf(get_main_win())
	local ns_id = child.lua_get([[require("codeforge.preview")._namespace]]) or 0
	local marks = child.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })
	local has_green = false
	for _, mark in ipairs(marks) do
		if mark[4] and mark[4].hl_group == "CodeForgePreviewAdd" then
			has_green = true
			break
		end
	end
	MiniTest.expect.equality(has_green, true, {
		fail_reason = "Preview should have green highlight on added lines",
	})
end

T["Preview shows reda signs at deleted positions"] = function()
	setup_preview_state()
	child.cmd("CodeForge")
	local sidebar = get_sidebar_win()
	child.api.nvim_set_current_win(sidebar)
	child.type_keys("3gg")

	local buf = child.api.nvim_win_get_buf(get_main_win())
	local ns_id = child.lua_get([[require("codeforge.preview")._namespace]]) or 0
	local marks = child.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })
	local has_red = false
	for _, mark in ipairs(marks) do
		if mark[4] and mark[4].sign_hl_group == "CodeForgePreviewDelete" then
			has_red = true
			break
		end
	end
	MiniTest.expect.equality(has_red, true, {
		fail_reason = "Preview should have red signs at deleted positions",
	})
end

return T
