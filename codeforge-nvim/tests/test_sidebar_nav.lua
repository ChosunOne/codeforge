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

---The sidebar window (filetype == "codeforge"), or nil.
local function sidebar_win()
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_get_option_value("filetype", { buf = b }) == "codeforge" then
			return w
		end
	end
	return nil
end

---A 1:1 modify hunk with the description/status the sidebar requires.
local function modify_hunk(id, at, old, new)
	return {
		id = id,
		description = id,
		status = "modified",
		old_start = at,
		old_lines = 1,
		new_start = at,
		new_lines = 1,
		lines = { "-" .. old, "+" .. new },
	}
end

T["<CR> on a sidebar hunk jumps the review cursor to that hunk and keeps sidebar focus"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local h1 = modify_hunk("hunk-2", 2, "b", "B")
	local h2 = modify_hunk("hunk-4", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.cmd("CodeForge")
	child.type_keys("3gg")
	child.type_keys("o")
	child.type_keys("5gg")
	child.type_keys("<CR>")

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "review buffer should be open after <CR>" })
	local rwin = Q.win_for_buf(buf)
	MiniTest.expect.equality(rwin ~= nil, true, { fail_reason = "review buffer should be shown in a window" })

	local cursor = child.api.nvim_win_get_cursor(rwin)
	MiniTest.expect.equality(cursor[1], 4, {
		fail_reason = "review cursor should jump to hunk-4's line 4, got " .. tostring(cursor[1]),
	})

	MiniTest.expect.equality(
		child.api.nvim_get_current_win() == sidebar_win(),
		true,
		{ fail_reason = "focus should remain in the sidebar after <CR>" }
	)
end

return T
