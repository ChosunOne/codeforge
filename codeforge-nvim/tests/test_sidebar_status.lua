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
		if child.api.nvim_buf_get_option(b, "filetype") == "codeforge" then
			return w
		end
	end
	return nil
end

local function sidebar_buf()
	local w = sidebar_win()
	return w and child.api.nvim_win_get_buf(w)
end

local function dapui_ns()
	return child.lua_get([[vim.api.nvim_create_namespace("dapui")]])
end

---The hl_group of the canvas match covering 0-indexed byte `col` on 1-indexed
---`line`, or nil if none.
local function hl_at(buf, line, col)
	local ns = dapui_ns()
	local row = line - 1
	local marks = child.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
	for _, m in ipairs(marks) do
		local d = m[4]
		if d and d.end_col and d.hl_group and m[2] == row and col >= m[3] and col < d.end_col then
			return d.hl_group
		end
	end
	return nil
end

---Poll up to ~1s for `pred` to return true (async sidebar render).
local function wait_for(pred)
	for _ = 1, 100 do
		if pred() then
			return true
		end
		child.lua([[vim.wait(10)]])
	end
	return pred()
end

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

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	local buf = Q.find_buf(path)
	local win = Q.win_for_buf(buf)
	return buf, win
end

T["accepting a hunk shows a green full circle in the sidebar; pending stays empty"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local h1 = modify_hunk("hunk-2", 2, "b", "B")
	local h2 = modify_hunk("hunk-4", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.cmd("CodeForge")
	child.type_keys("3gg")
	child.type_keys("o")

	local _, win = open_review(path)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a") -- accept hunk-2

	local sb = sidebar_buf()
	MiniTest.expect.equality(sb ~= nil, true, { fail_reason = "sidebar buffer not found" })
	local ok = wait_for(function()
		local lines = child.api.nvim_buf_get_lines(sb, 0, -1, false)
		return lines[4] and lines[4]:find("●", 1, true) ~= nil
	end)
	MiniTest.expect.equality(ok, true, { fail_reason = "accepted hunk row never showed ●" })

	local lines = child.api.nvim_buf_get_lines(sb, 0, -1, false)
	MiniTest.expect.equality(
		lines[4]:find("●", 1, true) ~= nil,
		true,
		{ fail_reason = "accepted hunk should show ●, got: " .. lines[4] }
	)
	MiniTest.expect.equality(
		lines[5]:find("○", 1, true) ~= nil and lines[5]:find("●", 1, true) == nil,
		true,
		{ fail_reason = "pending hunk should show ○ not ●, got: " .. lines[5] }
	)
	local col = lines[4]:find("●", 1, true) - 1
	MiniTest.expect.equality(
		hl_at(sb, 4, col) == "CodeForgeReviewAccepted",
		true,
		{ fail_reason = "accepted ● should be green, got " .. tostring(hl_at(sb, 4, col)) }
	)
end

T["rejecting a hunk shows a red full circle, distinct from accepted green"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local h1 = modify_hunk("hunk-2", 2, "b", "B")
	local h2 = modify_hunk("hunk-4", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.cmd("CodeForge")
	child.type_keys("3gg")
	child.type_keys("o")

	local _, win = open_review(path)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a") -- accept hunk-2
	child.api.nvim_win_set_cursor(win, { 4, 0 })
	child.type_keys("<C-x>j") -- reject hunk-4

	local sb = sidebar_buf()
	MiniTest.expect.equality(sb ~= nil, true, { fail_reason = "sidebar buffer not found" })
	local ok = wait_for(function()
		local lines = child.api.nvim_buf_get_lines(sb, 0, -1, false)
		return lines[4] and lines[5] and lines[4]:find("●", 1, true) ~= nil and lines[5]:find("●", 1, true) ~= nil
	end)
	MiniTest.expect.equality(ok, true, { fail_reason = "both rows never showed ●" })

	local lines = child.api.nvim_buf_get_lines(sb, 0, -1, false)
	local col4 = lines[4]:find("●", 1, true) - 1
	local col5 = lines[5]:find("●", 1, true) - 1
	MiniTest.expect.equality(
		hl_at(sb, 4, col4) == "CodeForgeReviewAccepted",
		true,
		{ fail_reason = "hunk-2 ● should be green (accepted), got " .. tostring(hl_at(sb, 4, col4)) }
	)
	MiniTest.expect.equality(
		hl_at(sb, 5, col5) == "CodeForgeReviewRejected",
		true,
		{ fail_reason = "hunk-4 ● should be red (rejected), got " .. tostring(hl_at(sb, 5, col5)) }
	)
end

return T
