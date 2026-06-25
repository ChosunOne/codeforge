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

	local U = child.lua_get(string.format([[require("codeforge.state").get_review(%s).U]], vim.inspect(path)))

	Q.expect_lines("snapshot U", U, O)
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

	local U = child.lua_get(string.format([[require("codeforge.state").get_review(%s).U]], vim.inspect(path)))
	Q.expect_lines("snapshot U", U, { "a", "X", "c" })

	local buf = Q.find_buf(path)
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("proposal P", got, { "a", "b", "B", "c" })
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

	local U = child.lua_get(string.format([[require("codeforge.state").get_review(%s).U]], vim.inspect(path)))

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
		child.api.nvim_buf_get_option(buf, "modified"),
		true,
		{ fail_reason = "buffer should be modified after loading P" }
	)
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

	local review = child.lua_get(string.format([[require("codeforge.state").get_review(%s)]], vim.inspect(path)))
	MiniTest.expect.equality(review == nil, true, { fail_reason = "review record should be cleared after dismiss" })
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

	local review = child.lua_get(string.format([[require("codeforge.state").get_review(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(review ~= nil, true, { fail_reason = "<CR> on file line should open review" })

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(buf ~= nil, true)
	local got = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	Q.expect_lines("proposal P", got, { "a", "b", "B", "c" })
end

return T
