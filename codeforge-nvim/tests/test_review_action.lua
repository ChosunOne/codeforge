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

local function ns()
	return child.lua_get([[require("codeforge.review.diff").namespace]])
end

local function hunk_status(path, hunk_id)
	return child.lua_get(
		string.format(
			[=[((require("codeforge.state").get_review(%s) or {}).hunk_status or {})[%s]]=],
			vim.inspect(path),
			vim.inspect(hunk_id)
		)
	)
end

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
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

T["reject on a pure-insert hunk removes the added lines and marks it rejected"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.insert_hunk("hunk-ins", 2, { "B" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "b", "c" })

	MiniTest.expect.equality(
		F.has_keymap(buf, "<C-x>j"),
		true,
		{ fail_reason = "no <C-x>j keymap on the review buffer" }
	)

	local win = Q.win_for_buf(buf)
	MiniTest.expect.equality(win ~= nil, true, { fail_reason = "review buffer not shown in a window" })
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- 1-indexed row 2 == 0-indexed row 1

	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "add highlight should be on row 1 before reject" }
	)

	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-ins") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "add highlight should be removed after reject" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["reject on a replace hunk restores the original line and marks it rejected"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.replace_hunk("hunk-rep", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "deletion fold should be on row 0 before reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "add highlight should be on row 1 before reject" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "B"
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-rep") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "deletion fold should be removed after reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "add highlight should be removed after reject" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["reject on a delete-only hunk restores the removed lines"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.delete_hunk("hunk-del", 2, { "b" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "c" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "deletion fold should be on row 0 before reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "row 1 should not carry an add highlight (delete-only hunk)" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 1, 0 }) -- row 0, the fold anchor "a"
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-del") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "deletion fold should be removed after reject" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["reject restores the user's pre-review edits (U), not the base (O)"] = function()
	local O = { "a", "b", "c" }
	local U = { "a", "b-user", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-rep", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "B"
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject (U, not O)", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b-user", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-rep") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["reject with coordinate drift restores the right U lines"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local U = { "a", "USER", "b", "c-USER", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-drift", 3, "c", "C")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "C", "d", "e" })

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 3, 0 }) -- row 2, the added line "C"
	child.type_keys("<C-x>j")

	Q.expect_lines(
		"after reject (drifted + edited U)",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "b", "c-USER", "d", "e" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-drift") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["accept merges U's region edits with the proposal (clean 3-way)"] = function()
	local O = { "a", "p", "m", "q", "d" }
	local U = { "a", "p", "m", "Q", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = {
		id = "hunk-acc",
		old_start = 2,
		old_lines = 3,
		new_start = 2,
		new_lines = 3,
		lines = { "-p", "-m", "-q", "+P", "+m", "+q" },
	}
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "P", "m", "q", "d" })

	MiniTest.expect.equality(
		F.has_keymap(buf, "<C-x>a"),
		true,
		{ fail_reason = "no <C-x>a keymap on the review buffer" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "P"
	child.type_keys("<C-x>a")

	Q.expect_lines(
		"after accept (combined U+P)",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "P", "m", "Q", "d" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-acc") == "accepted",
		true,
		{ fail_reason = "hunk should be marked 'accepted'" }
	)
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "deletion fold should be removed after accept" }
	)

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["accept on a conflicting region marks it conflicted and leaves the buffer untouched"] = function()
	local O = { "a", "b", "c" }
	local U = { "a", "b-user", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-conf", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "B"

	-- decorations present before accept
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "fold should be present before accept" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "add highlight should be present before accept" }
	)

	child.type_keys("<C-x>a")

	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "conflicted",
		true,
		{ fail_reason = "hunk should be marked 'conflicted'" }
	)
	Q.expect_lines("buffer unchanged on conflict", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) ~= nil,
		true,
		{ fail_reason = "fold should remain on conflict (unresolved)" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "add highlight should remain on conflict (unresolved)" }
	)
end

T["<C-x>c resolve flow: take ours then confirm yields U[R] and clears the conflict"] = function()
	local O = { "a", "b", "c" }
	local U = { "a", "b-user", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-conf", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 }) -- row 1, the added line "B"

	child.type_keys("<C-x>a")
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "conflicted",
		true,
		{ fail_reason = "precondition: hunk should be conflicted" }
	)

	MiniTest.expect.equality(
		F.has_keymap(buf, "<C-x>c"),
		true,
		{ fail_reason = "no <C-x>c keymap on the review buffer" }
	)

	child.type_keys("<C-x>c")

	local scratches, ours_buf, base_buf = {}, nil, nil
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		local name = child.api.nvim_buf_get_name(b)
		if name:match("codeforge%.resolve") then
			scratches[#scratches + 1] = b
			local lines = child.api.nvim_buf_get_lines(b, 0, -1, false)
			if lines[2] == "b-user" then
				ours_buf = b
			end
			if lines[2] == "b" then
				base_buf = b
			end
		end
	end
	MiniTest.expect.equality(
		#scratches == 2,
		true,
		{ fail_reason = "resolve should open 2 scratch buffers (ours + base)" }
	)
	MiniTest.expect.equality(ours_buf ~= nil, true, { fail_reason = "ours scratch (U[R]) not found" })
	MiniTest.expect.equality(base_buf ~= nil, true, { fail_reason = "base scratch (O[R]) not found" })
	MiniTest.expect.equality(
		child.api.nvim_buf_get_option(ours_buf, "modifiable") == false,
		true,
		{ fail_reason = "ours scratch should be read-only" }
	)
	MiniTest.expect.equality(
		child.api.nvim_buf_get_option(base_buf, "modifiable") == false,
		true,
		{ fail_reason = "base scratch should be read-only" }
	)
	local function win_diff(b)
		for _, w in ipairs(child.api.nvim_list_wins()) do
			if child.api.nvim_win_get_buf(w) == b then
				return child.api.nvim_win_get_option(w, "diff")
			end
		end
		return false
	end
	MiniTest.expect.equality(
		win_diff(buf) == true,
		true,
		{ fail_reason = "live buffer should be diffthis'd after <C-x>c" }
	)

	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>o"), true, { fail_reason = "no <C-x>o (take ours) keymap" })
	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>f"), true, { fail_reason = "no <C-x>d (confirm) keymap" })

	child.type_keys("<C-x>o")
	child.type_keys("<C-x>f")

	Q.expect_lines("after resolve (take ours)", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b-user", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk should be 'accepted' after confirm" }
	)
	local remaining = 0
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			remaining = remaining + 1
		end
	end
	MiniTest.expect.equality(remaining == 0, true, { fail_reason = "scratch buffers should be closed after confirm" })
	MiniTest.expect.equality(win_diff(buf) == false, true, { fail_reason = "diff should be off after confirm" })
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "fold should be removed after resolve" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "add highlight should be removed after resolve" }
	)
end

T["resolve: take base (O) then confirm reverts the region to O[R]"] = function()
	local O = { "a", "b", "c" }
	local U = { "a", "b-user", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-conf", 2, "b", "B")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a") -- conflict
	child.type_keys("<C-x>c") -- enter resolve
	child.type_keys("<C-x>p") -- take base (O)
	child.type_keys("<C-x>f") -- confirm

	Q.expect_lines("after resolve (take base)", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk should be 'accepted' after confirm" }
	)
end

T["dismiss assembles final: keeps resolved hunks, reverts pending to U"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("hunk-keep", 2, "b", "B")
	local h2 = F.insert_hunk("hunk-pending", 5, { "D2" })
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c", "d", "D2" })

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(
		hunk_status(path, "hunk-keep") == "accepted",
		true,
		{ fail_reason = "precondition: hunk1 should be accepted" }
	)
	Q.expect_lines("hunk2 still pending", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c", "d", "D2" })

	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>d"), true, { fail_reason = "no <C-x>d (dismiss) keymap" })

	child.type_keys("<C-x>d")

	Q.expect_lines("final after dismiss", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c", "d" })
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(path))) == true,
		true,
		{ fail_reason = "review state should be cleared after dismiss" }
	)
	MiniTest.expect.equality(
		#child.api.nvim_buf_get_extmarks(buf, n, 0, -1, {}) == 0,
		true,
		{ fail_reason = "all extmarks should be cleared after dismiss" }
	)
end

return T
