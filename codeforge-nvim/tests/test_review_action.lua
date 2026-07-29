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
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "a modify hunk has no removal fold before reject" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "modified highlight should be on row 1 before reject" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>j")

	Q.expect_lines("after reject", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-rep") == "rejected",
		true,
		{ fail_reason = "hunk should be marked 'rejected'" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) == nil,
		true,
		{ fail_reason = "modified highlight should be removed after reject" }
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
	child.api.nvim_win_set_cursor(win, { 1, 0 })
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
	child.api.nvim_win_set_cursor(win, { 2, 0 })
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
	child.api.nvim_win_set_cursor(win, { 3, 0 })
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
	child.api.nvim_win_set_cursor(win, { 2, 0 })
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
	child.api.nvim_win_set_cursor(win, { 2, 0 })

	-- decorations present before accept
	MiniTest.expect.equality(
		Q.fold_at(buf, n, 0) == nil,
		true,
		{ fail_reason = "a modify hunk has no removal fold before accept" }
	)
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "modified highlight should be present before accept" }
	)

	child.type_keys("<C-x>a")

	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "conflicted",
		true,
		{ fail_reason = "hunk should be marked 'conflicted'" }
	)
	Q.expect_lines("buffer unchanged on conflict", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })
	MiniTest.expect.equality(
		Q.hl_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "modified highlight should remain on conflict (unresolved)" }
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
	child.api.nvim_win_set_cursor(win, { 2, 0 })

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

	local resolve_buf = nil
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	MiniTest.expect.equality(resolve_buf ~= nil, true, { fail_reason = "resolve should open a scratch buffer" })
	local lines = child.api.nvim_buf_get_lines(resolve_buf, 0, -1, false)
	Q.expect_lines("conflicted buffer", lines, {
		"a",
		"<<<<<<< ours",
		"b-user",
		"=======",
		"B",
		">>>>>>> proposal",
		"c",
	})
	MiniTest.expect.equality(
		child.api.nvim_buf_get_option(resolve_buf, "modifiable") == true,
		true,
		{ fail_reason = "resolve buffer should be editable" }
	)
	MiniTest.expect.equality(
		F.has_keymap(resolve_buf, "<C-x>o"),
		true,
		{ fail_reason = "no <C-x>o (take ours) keymap" }
	)
	MiniTest.expect.equality(F.has_keymap(resolve_buf, "<C-x>f"), true, { fail_reason = "no <C-x>f (confirm) keymap" })

	child.type_keys("<C-x>o")
	Q.expect_lines(
		"after take-ours (markers + proposal side stripped)",
		child.api.nvim_buf_get_lines(resolve_buf, 0, -1, false),
		{ "a", "b-user", "c" }
	)
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
	MiniTest.expect.equality(remaining, 0, { fail_reason = "scratch buffers should be closed after confirm" })
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

T["a free-form edit above a hunk moves that hunk's sign (no action involved)"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.insert_hunk("hunk-add", 5, { "Z" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c", "d", "Z", "e" })

	local pre = Q.sign_at(buf, n, 4)
	MiniTest.expect.equality(
		pre ~= nil,
		true,
		{ fail_reason = "hunk-add should have a sign on row 5 (idx 4) before the edit" }
	)

	child.api.nvim_buf_set_lines(buf, 0, 0, false, { "x1", "x2" })
	child.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	child.lua([[vim.wait(300)]])

	local moved = Q.sign_at(buf, n, 6)
	MiniTest.expect.equality(
		moved ~= nil,
		true,
		{ fail_reason = "hunk-add sign should follow 'Z' to idx 6 after inserting 2 lines above" }
	)
	MiniTest.expect.equality(
		moved and moved.sign_hl_group,
		"CodeForgeHunkAdded",
		{ fail_reason = "shifted sign should still be CodeForgeHunkAdded" }
	)
	MiniTest.expect.equality(
		Q.sign_at(buf, n, 4),
		nil,
		{ fail_reason = "no sign should remain on the old idx 4 after the edit" }
	)
end

T["deleting a hunk's line drops its sign (the hunk is no longer locatable there)"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local hunk = F.insert_hunk("hunk-add", 3, { "Z" })
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "Z", "c", "d", "e" })
	MiniTest.expect.equality(
		Q.sign_at(buf, n, 2) ~= nil,
		true,
		{ fail_reason = "hunk-add should have a sign on the 'Z' line (idx 2) before the delete" }
	)

	child.api.nvim_buf_set_lines(buf, 2, 3, false, {})
	Q.expect_lines("after delete", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c", "d", "e" })
	child.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
	child.lua([[vim.wait(300)]])

	local signs = child.lua_get(
		string.format(
			[[#vim.tbl_filter(function(m) return m[4] and m[4].sign_text end, vim.api.nvim_buf_get_extmarks(%d, %d, 0, -1, {}))]],
			buf,
			n
		)
	)
	MiniTest.expect.equality(signs, 0, { fail_reason = "no hunk sign should remain after its line was deleted" })
	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[[(require("codeforge.state").get_review(%s)):hunk_row("hunk-add") == nil]],
				vim.inspect(path)
			)
		),
		true,
		{ fail_reason = "hunk_row should be nil once the hunk's only line is deleted" }
	)
end

T["resolve shifts later hunks' signs by the line-count delta (no stale signs)"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local U = { "a", "b-user", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk_conf = F.replace_hunk("hunk-conf", 2, "b", "B1", "B2")
	local hunk_add = F.insert_hunk("hunk-add", 5, { "Z" })
	F.seed_change(path, O, { hunk_conf, hunk_add })

	local buf = open_review(path)
	local n = ns()
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B1", "B2", "c", "d", "Z", "e" })

	local pre = Q.sign_at(buf, n, 5)
	MiniTest.expect.equality(pre ~= nil, true, { fail_reason = "hunk-add should have a sign at row 5 before resolve" })
	MiniTest.expect.equality(
		pre and pre.sign_hl_group,
		"CodeForgeHunkAdded",
		{ fail_reason = "hunk-add sign should be CodeForgeHunkAdded before resolve" }
	)

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "conflicted",
		true,
		{ fail_reason = "precondition: hunk-conf should be conflicted" }
	)
	child.type_keys("<C-x>c")

	local resolve_buf
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	MiniTest.expect.equality(resolve_buf ~= nil, true, { fail_reason = "resolve scratch not found" })
	child.type_keys("<C-x>o")
	child.type_keys("<C-x>f")

	Q.expect_lines(
		"after resolve",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "b-user", "c", "d", "Z", "e" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk-conf should be 'accepted' after confirm" }
	)
	local st_add = hunk_status(path, "hunk-add")
	MiniTest.expect.equality(
		st_add ~= "accepted" and st_add ~= "rejected",
		true,
		{ fail_reason = "hunk-add should remain untouched (not accepted/rejected)" }
	)
	local moved = Q.sign_at(buf, n, 4)
	MiniTest.expect.equality(
		moved ~= nil,
		true,
		{ fail_reason = "hunk-add sign should move to row 4 (on 'Z') after resolve" }
	)
	MiniTest.expect.equality(
		moved and moved.sign_hl_group,
		"CodeForgeHunkAdded",
		{ fail_reason = "shifted sign should still be CodeForgeHunkAdded" }
	)
	MiniTest.expect.equality(
		Q.sign_at(buf, n, 5),
		nil,
		{ fail_reason = "no sign should remain on row 5 ('e') after resolve" }
	)
	MiniTest.expect.equality(
		Q.sign_at(buf, n, 1),
		nil,
		{ fail_reason = "resolved hunk-conf should leave no sign on row 1" }
	)
	MiniTest.expect.equality(
		Q.sign_at(buf, n, 2),
		nil,
		{ fail_reason = "resolved hunk-conf should leave no sign on row 2" }
	)
end

T["resolve view: single editable conflict buffer with git merge markers + syntax + winbar"] = function()
	local O = { "local M = {}", "function M.f()", "  return 'b'", "end", "return M" }
	local U = { "local M = {}", "function M.f()", "  return 'b-user'", "end", "return M" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-conf", 3, "  return 'b'", "  return 'B'")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 3, 0 })
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")

	local resolve_buf, resolve_win
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	for _, w in ipairs(child.api.nvim_list_wins()) do
		if child.api.nvim_win_get_buf(w) == resolve_buf then
			resolve_win = w
		end
	end
	MiniTest.expect.equality(resolve_buf ~= nil, true, { fail_reason = "resolve scratch not found" })
	MiniTest.expect.equality(resolve_win ~= nil, true, { fail_reason = "resolve window not found" })

	MiniTest.expect.equality(
		child.api.nvim_buf_get_option(resolve_buf, "filetype"),
		"lua",
		{ fail_reason = "resolve buffer should have filetype=lua" }
	)
	MiniTest.expect.equality(
		child.api.nvim_buf_get_option(resolve_buf, "modifiable") == true,
		true,
		{ fail_reason = "resolve buffer should be editable" }
	)

	Q.expect_lines("conflict buffer", child.api.nvim_buf_get_lines(resolve_buf, 0, -1, false), {
		"local M = {}",
		"function M.f()",
		"<<<<<<< ours",
		"  return 'b-user'",
		"=======",
		"  return 'B'",
		">>>>>>> proposal",
		"end",
		"return M",
	})

	local wb = child.api.nvim_win_get_option(resolve_win, "winbar") or ""
	MiniTest.expect.equality(
		wb:find("<C-x>o", 1, true) ~= nil,
		true,
		{ fail_reason = "winbar should hint <C-x>o, got: " .. wb }
	)
	MiniTest.expect.equality(
		wb:find("<C-x>f", 1, true) ~= nil,
		true,
		{ fail_reason = "winbar should hint <C-x>f, got: " .. wb }
	)

	child.type_keys("<C-x>f")
	MiniTest.expect.equality(child.api.nvim_buf_is_valid(resolve_buf), false, {
		fail_reason = "resolve scratch should be deleted after confirm",
	})
end

T["resolve: the conflict block is marked with a gutter sign (not a full-line highlight)"] = function()
	local O = { "local M = {}", "function M.f()", "  return 'b'", "end", "return M" }
	local U = { "local M = {}", "function M.f()", "  return 'b-user'", "end", "return M" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local hunk = F.replace_hunk("hunk-conf", 3, "  return 'b'", "  return 'B'")
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 3, 0 })
	child.type_keys("<C-x>a") -- conflict
	child.type_keys("<C-x>c") -- enter resolve

	local resolve_buf
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	MiniTest.expect.equality(resolve_buf ~= nil, true, { fail_reason = "resolve scratch not found" })
	local resolve_ns = child.lua_get([[vim.api.nvim_create_namespace("codeforge_resolve")]])
	local function sign_row(row)
		local d = Q.sign_at(resolve_buf, resolve_ns, row)
		return d and (d.sign_hl_group or d.sign_text) or nil
	end
	for _, row in ipairs({ 2, 3, 4, 5, 6 }) do
		MiniTest.expect.equality(sign_row(row) == "CodeForgeReviewConflicted", true, {
			fail_reason = "conflict block row "
				.. row
				.. " should have a CodeForgeReviewConflicted gutter sign, got "
				.. tostring(sign_row(row)),
		})
	end
	for _, row in ipairs({ 0, 1, 7, 8 }) do
		MiniTest.expect.equality(sign_row(row) == nil, true, {
			fail_reason = "non-conflict row " .. row .. " should have no gutter sign, got " .. tostring(sign_row(row)),
		})
	end
	local function hl_row(row)
		local d = Q.hl_at(resolve_buf, resolve_ns, row)
		return d and d.hl_group or nil
	end
	for _, row in ipairs({ 2, 4, 6 }) do
		MiniTest.expect.equality(hl_row(row) == "CodeForgeReviewConflicted", true, {
			fail_reason = "marker row "
				.. row
				.. " should have a full-line CodeForgeReviewConflicted text highlight, got "
				.. tostring(hl_row(row)),
		})
	end
	for _, row in ipairs({ 3, 5 }) do
		MiniTest.expect.equality(hl_row(row) == nil, true, {
			fail_reason = "content row "
				.. row
				.. " should have NO text highlight (gutter sign only), got "
				.. tostring(hl_row(row)),
		})
	end
end

T["resolve: with a previous conflict's markers left in the file, the next resolve highlights ITS block, not the stale one"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local U = { "a", "b-user", "c", "d", "e-user" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local pre_buf = Q.find_buf(path)
	child.api.nvim_buf_set_lines(pre_buf, 0, -1, false, U)
	local h1 = F.replace_hunk("hunk-b", 2, "b", "B")
	local h2 = F.replace_hunk("hunk-e", 5, "e", "E")
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)

	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")
	child.type_keys("<C-x>f")
	Q.expect_lines("after resolve1 (markers kept)", child.api.nvim_buf_get_lines(buf, 0, -1, false), {
		"a",
		"<<<<<<< ours",
		"b-user",
		"=======",
		"B",
		">>>>>>> proposal",
		"c",
		"d",
		"E",
	})

	child.api.nvim_win_set_cursor(win, { 9, 0 })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(
		hunk_status(path, "hunk-e"),
		"conflicted",
		{ fail_reason = "hunk-e should be conflicted (user edited line 5 too)" }
	)
	child.type_keys("<C-x>c")

	local resolve_buf
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	MiniTest.expect.equality(resolve_buf ~= nil, true, { fail_reason = "resolve scratch not found" })
	local resolve_ns = child.lua_get([[vim.api.nvim_create_namespace("codeforge_resolve")]])

	local lines = child.api.nvim_buf_get_lines(resolve_buf, 0, -1, false)
	local marker_rows = {}
	for i, l in ipairs(lines) do
		if l:sub(1, 7) == "<<<<<<<" then
			marker_rows[#marker_rows + 1] = i - 1
		end
	end
	MiniTest.expect.equality(
		#marker_rows >= 2,
		true,
		{ fail_reason = "resolve buffer should contain two conflict blocks, got: " .. vim.inspect(lines) }
	)

	local function sign_row(row)
		local d = Q.sign_at(resolve_buf, resolve_ns, row)
		return d ~= nil
	end
	local first_start = marker_rows[1]
	local second_start = marker_rows[2]
	for row = first_start, first_start + 4 do
		MiniTest.expect.equality(sign_row(row), false, {
			fail_reason = "stale conflict row " .. row .. " (" .. lines[row + 1] .. ") must NOT be highlighted",
		})
	end
	MiniTest.expect.equality(sign_row(second_start), true, {
		fail_reason = "current conflict row "
			.. second_start
			.. " ("
			.. lines[second_start + 1]
			.. ") must be highlighted",
	})
	local resolve_win
	for _, w in ipairs(child.api.nvim_list_wins()) do
		if child.api.nvim_win_get_buf(w) == resolve_buf then
			resolve_win = w
		end
	end
	local cur = child.api.nvim_win_get_cursor(resolve_win)[1] - 1
	MiniTest.expect.equality(cur == second_start, true, {
		fail_reason = "cursor should land on the current conflict's <<<<<<< (row "
			.. second_start
			.. "), got row "
			.. cur
			.. " ("
			.. tostring(lines[cur + 1])
			.. ")",
	})
end

T["resolve: <C-x>o typed in the conflict buffer takes ours (keybind fires via keypress)"] = function()
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
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")

	local resolve_buf
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	MiniTest.expect.equality(resolve_buf ~= nil, true, { fail_reason = "resolve scratch not found" })
	local resolve_win = Q.win_for_buf(resolve_buf)
	MiniTest.expect.equality(
		child.api.nvim_get_current_win() == resolve_win,
		true,
		{ fail_reason = "resolve buffer window should be focused so keybinds fire" }
	)
	child.type_keys("<C-x>o")
	child.type_keys("<C-x>f")
	Q.expect_lines(
		"after typed <C-x>o then <C-x>f",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "b-user", "c" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk should be accepted after typed confirm" }
	)
end

T["resolve: edit the conflict buffer by hand then confirm keeps the edit"] = function()
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
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")

	local resolve_buf = nil
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	local w2 = Q.win_for_buf(resolve_buf)
	child.api.nvim_set_current_win(w2)
	child.api.nvim_win_set_cursor(w2, { 2, 0 })
	child.type_keys("5dd")
	child.api.nvim_buf_set_lines(resolve_buf, 0, -1, false, { "a", "MERGED", "c" })
	child.type_keys("<C-x>f")

	Q.expect_lines(
		"after resolve (custom edit)",
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		{ "a", "MERGED", "c" }
	)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk should be 'accepted' after confirm" }
	)
end

T["a resolved hunk stays reachable: it can be re-resolved or rejected after confirm"] = function()
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
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")
	child.type_keys("<C-x>o")
	child.type_keys("<C-x>f")
	Q.expect_lines("after resolve", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b-user", "c" })
	MiniTest.expect.equality(hunk_status(path, "hunk-conf"), "accepted")

	local found = child.lua_get(
		string.format([[((require("codeforge.state").get_review(%s)):hunk_at_row(1) or {}).hunk_id]], vim.inspect(path))
	)
	MiniTest.expect.equality(
		found,
		"hunk-conf",
		{ fail_reason = "resolved hunk should still be locatable at its region, got " .. tostring(found) }
	)

	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>j") -- reject
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf"),
		"rejected",
		{ fail_reason = "resolved hunk should be rejectable after confirm" }
	)
end

T["resolve: confirm with markers still present keeps them verbatim (no stripping, no duplication)"] = function()
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
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")

	local resolve_buf = nil
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	local before = child.api.nvim_buf_get_lines(resolve_buf, 0, -1, false)
	local w2 = Q.win_for_buf(resolve_buf)
	child.api.nvim_set_current_win(w2)
	child.type_keys("<C-x>f")

	Q.expect_lines("confirm keeps unresolved markers verbatim", child.api.nvim_buf_get_lines(buf, 0, -1, false), before)
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk should be 'accepted' after confirm even with markers present" }
	)
end

T["resolve: <C-x>p take-proposal replaces the conflict block with the proposal side"] = function()
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
	child.type_keys("<C-x>a")
	child.type_keys("<C-x>c")

	local resolve_buf = nil
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b):match("codeforge%.resolve") then
			resolve_buf = b
		end
	end
	MiniTest.expect.equality(
		F.has_keymap(resolve_buf, "<C-x>p"),
		true,
		{ fail_reason = "no <C-x>p (take proposal) keymap" }
	)
	local w2 = Q.win_for_buf(resolve_buf)
	child.api.nvim_set_current_win(w2)
	child.type_keys("<C-x>p")
	Q.expect_lines(
		"after take-proposal (markers + ours side stripped)",
		child.api.nvim_buf_get_lines(resolve_buf, 0, -1, false),
		{ "a", "B", "c" }
	)

	child.type_keys("<C-x>f")
	Q.expect_lines("after resolve (take proposal)", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })
	MiniTest.expect.equality(
		hunk_status(path, "hunk-conf") == "accepted",
		true,
		{ fail_reason = "hunk should be 'accepted' after take-proposal + confirm" }
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
