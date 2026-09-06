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

T["open loads the proposal into the real file buffer"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "no buffer found for path" })
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("proposal P", got, { "a", "b", "B", "c" })

	local U =
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(path)))

	Q.expect_lines("snapshot U", U, O)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["open snapshots the user's unsaved edits as U"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)

	child.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "X", "c" })
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local U =
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(path)))
	Q.expect_lines("snapshot U", U, { "a", "X", "c" })

	local buf = Q.find_buf(path)
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("proposal P", got, { "a", "b", "B", "c" })

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["open reuses an already-loaded buffer"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.cmd("vsplit")
	local wins_before = child.api.nvim_list_wins()
	MiniTest.expect.equality(#wins_before, 2)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local matching = {}
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b) == path then
			matching[#matching + 1] = b
		end
	end
	MiniTest.expect.equality(#matching, 1, { fail_reason = "expected 1 buffer, got " .. #matching })

	local P = { "a", "b", "B", "c" }
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_buf_get_name(b) == path then
			local got = child.api.nvim_buf_get_lines(b, 0, -1, false)
			Q.expect_lines("window shows P", got, P)
		end
	end
end

T["open loads the file hidden if it is not already open"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	MiniTest.expect.equality(Q.find_buf(path) == nil, true, { fail_reason = "file should not be open yet" })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "open should load the file" })
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("proposal P", got, { "a", "b", "B", "c" })

	local U =
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(path)))

	Q.expect_lines("snapshot U", U, O)
end

T["open does not write to disk"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local disk = child.fn.readfile(path)
	Q.expect_lines("disk unchanged", disk, O)

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("modified", { buf = buf }),
		true,
		{ fail_reason = "buffer should be modified after loading P" }
	)
end

T["reopening an in-progress review preserves hunk status and U"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)

	child.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "X", "c" })
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	local function open()
		child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	end

	open()
	child.lua(string.format(
		[[
                    local r = require("codeforge.state").get_review(%s)
                    _G.__first_review = r
                    r.hunk_status["hunk-001"] = "conflicted"
            ]],
		vim.inspect(path)
	))

	open()

	MiniTest.expect.equality(
		child.lua_get(
			string.format([[require("codeforge.state").get_review(%s) == _G.__first_review]], vim.inspect(path))
		),
		true,
		{ fail_reason = "reopening created a new Review, discarding triage state" }
	)
	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[=[(require("codeforge.state").get_review(%s).hunk_status or {})["hunk-001"]]=],
				vim.inspect(path)
			)
		),
		"conflicted",
		{ fail_reason = "hunk status was reset on reopen" }
	)
	Q.expect_lines(
		"U preserved",
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).buf_snapshot]], vim.inspect(path))),
		{ "a", "X", "c" }
	)
	child.lua([[_G.__first_review = nil]])
end

T["dismiss restores the original U into the buffer"] = function()
	local O = { "a", "b", "c" }
	local U = { "a", "X", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(0, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	child.lua(string.format([[require("codeforge.review.buffer").dismiss(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("buffer restored to U", got, U)

	local review = child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(path)))
	MiniTest.expect.equality(review, true, { fail_reason = "review record should be cleared after dismiss" })
end

T["pressing <CR> on a file line in the sidebar opens the review buffer"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	child.cmd("CodeForge")
	child.type_keys("3gg")
	child.type_keys("<CR>")

	local review = child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(path)))

	MiniTest.expect.equality(review, true, { fail_reason = "<CR> on file line should open review" })

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true)
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("proposal P", got, { "a", "b", "B", "c" })
end

T["open shows the review buffer in a non-sidebar window and focuses it"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	MiniTest.expect.equality(Q.find_buf(path) == nil, true, { fail_reason = "file should not be open yet" })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "review buffer not created" })

	local win = Q.win_for_buf(buf)
	MiniTest.expect.equality(win ~= nil, true, { fail_reason = "review buffer not shown in any window" })
	MiniTest.expect.equality(
		not Q.is_sidebar_buf(buf),
		true,
		{ fail_reason = "review buffer shown in the sidebar window" }
	)

	MiniTest.expect.equality(
		child.api.nvim_get_current_win() == win,
		true,
		{ fail_reason = "review buffer window not focused" }
	)
end

T["open focuses the window already showing the review buffer"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-001", 2, "b", "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true)
	local win_before = Q.win_for_buf(buf)
	MiniTest.expect.equality(win_before ~= nil, true, { fail_reason = "file not shown before open" })
	local wins_before = #child.api.nvim_list_wins()

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(
		Q.win_for_buf(buf) == win_before,
		true,
		{ fail_reason = "review buffer moved to a different window" }
	)
	MiniTest.expect.equality(
		#child.api.nvim_list_wins() == wins_before,
		true,
		{ fail_reason = "open created a new window" }
	)
	MiniTest.expect.equality(
		child.api.nvim_get_current_win() == win_before,
		true,
		{ fail_reason = "existing review window not focused" }
	)
end

T["open on a newly added file shows the new content in the review buffer"] = function()
	local path = F.tmp_path()
	local lines = { "local M = {}", "function M.greet()", "  return 'hi'", "end", "return M" }
	F.seed_added_file(path, lines)

	MiniTest.expect.equality(Q.find_buf(path) == nil, true, { fail_reason = "file should not be open yet" })

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "review buffer not created" })
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
	local win = Q.win_for_buf(buf)

	MiniTest.expect.equality(win ~= nil, true, { fail_reason = "review buffer not shown in any window" })
	MiniTest.expect.equality(
		not Q.is_sidebar_buf(buf),
		true,
		{ fail_reason = "review buffer shown in the sidebar window" }
	)
	MiniTest.expect.equality(
		child.api.nvim_get_current_win() == win,
		true,
		{ fail_reason = "review buffer window not focused" }
	)
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("filetype", { buf = buf }),
		"lua",
		{ fail_reason = "review buffer for a .lua file should have filetype=lua" }
	)
end

return T
