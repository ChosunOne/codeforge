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

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
end

local function sidebar_buf()
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_get_option_value("filetype", { buf = b }) == "codeforge" then
			return b
		end
	end
	return nil
end

---Poll up to ~1s for a sidebar line containing `substr`.
local function await_sidebar_line(substr)
	for _ = 1, 40 do
		local sb = sidebar_buf()
		if sb then
			for _, l in ipairs(child.api.nvim_buf_get_lines(sb, 0, -1, false)) do
				if l:find(substr, 1, true) then
					return l
				end
			end
		end
		child.lua([[vim.wait(25)]])
	end
	return nil
end

---Seed a 2-hunk change, complete it via accepts (auto-completes), and
---return the path. Leaves the sidebar open.
local function complete_a_change()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	child.cmd("CodeForge")
	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	child.api.nvim_win_set_cursor(win, { 4, 0 })
	child.type_keys("<C-x>a")
	child.lua([[vim.wait(200)]])
	return path
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

T["completed changes render in a sidebar Completed section"] = function()
	local path = complete_a_change()

	local line = await_sidebar_line("Completed (1)")
	MiniTest.expect.equality(line ~= nil, true, {
		fail_reason = "completed section header missing, sidebar: "
			.. vim.inspect(sidebar_buf() and child.api.nvim_buf_get_lines(sidebar_buf(), 0, -1, false)),
	})
	local title_line = await_sidebar_line("Test")
	MiniTest.expect.equality(
		title_line:find("✓", 1, true) ~= nil or title_line:find("●", 1, true) ~= nil,
		true,
		{ fail_reason = "completed row should carry an outcome glyph, got: " .. title_line }
	)
end

T["pressing o on a completed row reopens it as a new review"] = function()
	local path = complete_a_change()

	-- find the completed row and press o on it
	local sb = sidebar_buf()
	local rows = child.api.nvim_buf_get_lines(sb, 0, -1, false)
	local row_no = nil
	for i, l in ipairs(rows) do
		if l:find("Test", 1, true) and i > 3 then
			row_no = i
			break
		end
	end
	MiniTest.expect.equality(row_no ~= nil, true, { fail_reason = "completed row not found" })
	local win = vim.iter(child.api.nvim_list_wins()):find(function(w)
		return child.api.nvim_win_get_buf(w) == sb
	end)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { row_no, 0 })
	child.type_keys("o")
	child.lua([[vim.wait(200)]])

	-- change is tracked again and selected
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 1, {
		fail_reason = "reopened change should be tracked",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change().id]]), "change-001", {
		fail_reason = "reopened change should be selected",
	})
	-- fresh review: all hunks pending, built from base over U = final content
	local review = child.lua_get(string.format([[require("codeforge.state").get_review(%s)]], vim.inspect(path)))
	MiniTest.expect.equality(review ~= nil, true, { fail_reason = "a fresh review should be open" })
	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[=[(function() local r = require("codeforge.state").get_review(%s); return r.hunk_status.h1 == nil and r.hunk_status.h2 == nil end)()]=],
				vim.inspect(path)
			)
		),
		true,
		{ fail_reason = "reopened review must start with all hunks pending" }
	)
	-- U is the completed final content: rejecting a hunk restores it
	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[=[(function() local r = require("codeforge.state").get_review(%s); return table.concat(r.buf_snapshot, "|") end)()]=],
				vim.inspect(path)
			)
		),
		"a|B|c|D|e",
		{ fail_reason = "reopened review's U must be the previous round's final content" }
	)
	-- log gained a reopened marker
	local log = child.lua_get([[require("codeforge.state").log]])
	MiniTest.expect.equality(log[#log].status, "reopened", { fail_reason = "reopened marker appended" })
end

T["reopening purges stale history for that change"] = function()
	local path = complete_a_change()

	-- the completion left two accept records in the undo stack
	MiniTest.expect.equality(
		child.lua_get([[#require("codeforge.history").undo_stack]]),
		2,
		{ fail_reason = "precondition: two undo transactions" }
	)

	-- reopen via the action (row press covered elsewhere)
	child.lua_get(
		string.format([[require("codeforge.sidebar.actions").reopen_completed("change-001")]], vim.inspect(path))
	)

	MiniTest.expect.equality(
		child.lua_get([[#require("codeforge.history").undo_stack]]),
		0,
		{ fail_reason = "stale records for the reopened change must be purged" }
	)
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.sidebar.actions").undo()]]),
		0,
		{ fail_reason = "undo after reopen is a no-op" }
	)
end

T["re-completed changes are listed once"] = function()
	local path = complete_a_change()

	-- revive via undo of the completing accept, then re-complete via redo
	child.lua_get([[require("codeforge.sidebar.actions").undo()]])
	child.lua_get([[require("codeforge.sidebar.actions").redo()]])

	MiniTest.expect.equality(await_sidebar_line("Completed (1)") ~= nil, true, {
		fail_reason = "completed section should still list exactly one entry",
	})
	MiniTest.expect.equality(await_sidebar_line("Completed (2)") ~= nil, false, {
		fail_reason = "re-completion must not duplicate the entry",
	})
end

T["completed section renders when there are no pending changes"] = function()
	local path = complete_a_change()
	-- the only change completed: sidebar shows the empty state AND the section
	MiniTest.expect.equality(await_sidebar_line("No pending changes") ~= nil, true, {
		fail_reason = "empty state should still render",
	})
	MiniTest.expect.equality(await_sidebar_line("Completed (1)") ~= nil, true, {
		fail_reason = "completed section should render below the empty state",
	})
	MiniTest.expect.equality(await_sidebar_line("Test") ~= nil, true, {
		fail_reason = "completed row should render",
	})
end

return T
