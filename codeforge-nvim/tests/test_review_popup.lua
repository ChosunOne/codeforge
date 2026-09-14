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

local function popup_ns()
	return child.lua_get([[require("codeforge.review.popup").namespace]])
end

---All floating windows as { win, buf, cfg } rows.
local function floats()
	return child.lua_get([[
		(function()
			local out = {}
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				local c = vim.api.nvim_win_get_config(w)
				if c and c.relative ~= "" then
					out[#out + 1] = { win = w, buf = vim.api.nvim_win_get_buf(w), cfg = c }
				end
			end
			return out
		end)()
	]])
end

---Lines of the single open float, or nil when there is none.
local function popup_lines()
	local fl = floats()
	if #fl == 0 then
		return nil
	end
	return child.api.nvim_buf_get_lines(fl[1].buf, 0, -1, false)
end

local function popup_config()
	local fl = floats()
	if #fl == 0 then
		return nil
	end
	return fl[1].cfg
end

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
end

---Focus the review window and put the cursor on 0-indexed `row`.
local function cursor_on(buf, row)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { row + 1, 0 })
end


---Assert the review buffer maps `lhs`, then press it. Guards against
---type_keys hanging on an unmapped prefix key (e.g. bare "g" after <C-x>).
local function press(buf, lhs)
	MiniTest.expect.equality(
		F.has_keymap(buf, lhs),
		true,
		{ fail_reason = "review buffer should map " .. lhs }
	)
	child.type_keys(lhs)
end

---Seed a two-hunk modified file: O = a b c d e, insert "B" before line 2 and
---"X" before line 5 (pure insertions). Proposal P = a B b c d X e:
---"B" sits at row 1 and "X" at row 5 (0-indexed).
local function seed_two_inserts(path)
	local O = { "a", "b", "c", "d", "e" }
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, {
		F.insert_hunk("hunk-1", 2, { "B" }),
		F.insert_hunk("hunk-2", 5, { "X" }),
	})
	return O
end

---Seed a one-hunk modified file replacing "b" with "B". P = a B c.
local function seed_replace(path)
	local O = { "a", "b", "c" }
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("hunk-1", 2, "b", "B") })
	return O
end

---Seed a one-hunk modified file deep in a long file: O = l1..l40, line 30
---replaced by L30. The hunk's only live line sits at row 29 (0-indexed).
local function seed_deep(path)
	local O = {}
	for i = 1, 40 do
		O[i] = "l" .. i
	end
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("hunk-1", 30, "l30", "L30") })
	return O
end

---1-based viewport row of 0-indexed buffer row `row0` in `win` (0 = off-screen).
local function viewport_row_of(win, row0)
	return child.lua_get(string.format([[vim.fn.screenpos(%d, %d, 0).row]], win, row0 + 1))
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 30, 100
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

-- Configuration -------------------------------------------------------------

T["config keeps only the hunk popup key; the losing variants are retired"] = function()
	local keys = child.lua_get([[require("codeforge").config.keymaps]])
	MiniTest.expect.equality(keys.toggle_hunk_diff, "<C-x>p", { fail_reason = "hunk popup key should default to <C-x>p" })
	MiniTest.expect.equality(
		keys.toggle_file_diff == nil,
		true,
		{ fail_reason = "the file popup lost the A/B test; its keymap must not linger" }
	)
	MiniTest.expect.equality(
		keys.toggle_inline_diff == nil,
		true,
		{ fail_reason = "the inline ghosts lost the A/B test; their keymap must not linger" }
	)
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge").config.inline_diff == nil]]),
		true,
		{ fail_reason = "the inline-diff config flag must be gone" }
	)
end

T["retired variants leave no keymaps on the review buffer"] = function()
	-- F.has_keymap compares lhs case-insensitively, which cannot tell
	-- <C-x>p from <C-x>P; retired-key checks need exact matching.
	local function has_keymap_exact(buf, lhs)
		for _, m in ipairs(child.api.nvim_buf_get_keymap(buf, "n")) do
			if m.lhs == lhs then
				return true
			end
		end
		return false
	end

	local path = F.tmp_path()
	seed_replace(path)
	local buf = open_review(path)

	MiniTest.expect.equality(F.has_keymap(buf, "<C-x>p"), true, { fail_reason = "the winner must stay mapped" })
	MiniTest.expect.equality(
		has_keymap_exact(buf, "<C-x>P"),
		false,
		{ fail_reason = "retired file popup key must not be mapped" }
	)
	MiniTest.expect.equality(
		has_keymap_exact(buf, "<C-x>g"),
		false,
		{ fail_reason = "retired inline ghost key must not be mapped" }
	)
end

T["oversized hunk diffs fill the window and truncate with a plain hint"] = function()
	local path = F.tmp_path()
	local O = { "a" }
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local adds = {}
	for i = 1, 30 do
		adds[i] = "added " .. i
	end
	F.seed_change(path, O, { F.insert_hunk("hunk-1", 1, adds) })
	local buf = open_review(path)

	cursor_on(buf, 0)
	press(buf, "<C-x>p")

	local h = child.api.nvim_win_get_height(Q.win_for_buf(buf))
	local cfg = popup_config()
	MiniTest.expect.equality(
		cfg.height,
		h - 3,
		{ fail_reason = "an oversized diff should cap the popup at the window height minus margins" }
	)
	local lines = popup_lines()
	MiniTest.expect.equality(#lines, h - 3, { fail_reason = "truncated rows should match the popup height" })
	MiniTest.expect.equality(
		lines[#lines],
		string.format("… +%d more lines", 31 - (h - 4)),
		{ fail_reason = "the truncation hint should say how many rows were hidden, with no cross-reference" }
	)
end

-- Hunk popup ----------------------------------------------------------------

T["<C-x>p opens a non-focusable float showing the selected hunk's diff vs pre-review"] = function()
	local path = F.tmp_path()
	seed_replace(path)
	local buf = open_review(path)

	cursor_on(buf, 1) -- the "B" line of hunk-1
	press(buf, "<C-x>p")

	local fl = floats()
	MiniTest.expect.equality(#fl, 1, { fail_reason = "exactly one float should be open" })
	MiniTest.expect.equality(
		fl[1].cfg.focusable,
		false,
		{ fail_reason = "hunk popup should be non-focusable so the review buffer keeps the cursor" }
	)

	local lines = popup_lines()
	Q.expect_lines("hunk popup", lines, { "hunk 1/1 (pending)", "-b", "+B" })

	-- diff rows are highlighted with the shared hunk groups
	local marks = Q.extmarks(fl[1].buf, popup_ns())
	local removed_hl, added_hl = false, false
	for _, m in ipairs(marks) do
		if m[4] and m[4].hl_group == "CodeForgeHunkDeleted" and m[2] == 1 then
			removed_hl = true
		end
		if m[4] and m[4].hl_group == "CodeForgeHunkAdded" and m[2] == 2 then
			added_hl = true
		end
	end
	MiniTest.expect.equality(removed_hl, true, { fail_reason = "'-b' row should carry CodeForgeHunkDeleted" })
	MiniTest.expect.equality(added_hl, true, { fail_reason = "'+B' row should carry CodeForgeHunkAdded" })

	Q.focus_buf(buf)
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["<C-x>p again closes the popup (toggle)"] = function()
	local path = F.tmp_path()
	seed_replace(path)
	local buf = open_review(path)

	cursor_on(buf, 1)
	press(buf, "<C-x>p")
	MiniTest.expect.equality(#floats(), 1, { fail_reason = "popup should be open after first press" })

	press(buf, "<C-x>p")
	MiniTest.expect.equality(#floats(), 0, { fail_reason = "popup should close on second press" })
end

T["<C-x>p re-anchors when the cursor moves to a different hunk"] = function()
	local path = F.tmp_path()
	seed_two_inserts(path)
	local buf = open_review(path)

	cursor_on(buf, 5) -- the "X" line of hunk-2
	press(buf, "<C-x>p")
	MiniTest.expect.equality(popup_lines()[1], "hunk 2/2 (pending)", { fail_reason = "popup should show hunk-2" })

	cursor_on(buf, 1) -- the "B" line of hunk-1
	press(buf, "<C-x>p")
	MiniTest.expect.equality(#floats(), 1, { fail_reason = "popup should stay open when re-anchoring" })
	MiniTest.expect.equality(popup_lines()[1], "hunk 1/2 (pending)", { fail_reason = "popup should now show hunk-1" })

	press(buf, "<C-x>p")
	MiniTest.expect.equality(#floats(), 0, { fail_reason = "same-hunk press should toggle the popup closed" })
end

T["<C-x>p on a rejected hunk shows no-difference instead of a stale diff"] = function()
	local path = F.tmp_path()
	seed_two_inserts(path)
	local buf = open_review(path)

	cursor_on(buf, 1)
	press(buf, "<C-x>j") -- reject hunk-1 (hunk-2 keeps the review pending)
	press(buf, "<C-x>p")

	local lines = popup_lines()
	MiniTest.expect.equality(
		lines[1],
		"hunk 1/2 (rejected)",
		{ fail_reason = "popup header should carry the hunk's triage status" }
	)
	MiniTest.expect.equality(
		#lines,
		2,
		{ fail_reason = "a rejected hunk has no diff vs pre-review; got " .. vim.inspect(lines) }
	)
	MiniTest.expect.equality(
		lines[2]:find("no difference", 1, true) ~= nil,
		true,
		{ fail_reason = "rejected hunk should show a 'no difference' note" }
	)
end

T["<C-x>p with the cursor outside any hunk opens nothing"] = function()
	local path = F.tmp_path()
	seed_two_inserts(path)
	local buf = open_review(path)

	cursor_on(buf, 0) -- context line "a", not part of any hunk
	press(buf, "<C-x>p")

	MiniTest.expect.equality(#floats(), 0, { fail_reason = "no float should open without a hunk under the cursor" })
end

T["dismiss tears down an open popup"] = function()
	local path = F.tmp_path()
	seed_replace(path)
	local buf = open_review(path)

	cursor_on(buf, 1)
	press(buf, "<C-x>p")
	MiniTest.expect.equality(#floats(), 1, { fail_reason = "popup should be open before dismiss" })

	press(buf, "<C-x>d")
	MiniTest.expect.equality(#floats(), 0, { fail_reason = "dismiss should close the popup" })
end

T["popup refreshes (and re-anchors) when a different hunk is rejected"] = function()
	local path = F.tmp_path()
	seed_two_inserts(path)
	local buf = open_review(path)

	cursor_on(buf, 5) -- hunk-2's "X" at row 5
	press(buf, "<C-x>p")
	local before = popup_config().row
	MiniTest.expect.equality(#floats(), 1, { fail_reason = "popup should be open on hunk-2" })

	child.lua(string.format(
		[[require("codeforge.state").get_review(%s):reject_hunk(1)]],
		vim.inspect(path)
	))

	MiniTest.expect.equality(#floats(), 1, { fail_reason = "popup should survive rejecting a different hunk" })
	MiniTest.expect.equality(
		popup_lines()[2],
		"+X",
		{ fail_reason = "popup content should be refreshed, not stale" }
	)
	MiniTest.expect.equality(
		popup_config().row,
		before - 1,
		{ fail_reason = "rejecting the insert above should shift the popup's anchor row up by one" }
	)
end

T["completing the change closes an open popup"] = function()
	local path = F.tmp_path()
	seed_two_inserts(path)
	local buf = open_review(path)

	cursor_on(buf, 4)
	press(buf, "<C-x>p")
	child.lua(string.format(
		[[local r = require("codeforge.state").get_review(%s); r:reject_hunk(1); r:reject_hunk(4)]],
		vim.inspect(path)
	))

	MiniTest.expect.equality(#floats(), 0, { fail_reason = "auto-completion (via dismiss) should close the popup" })
end

T["<C-x>p works on an already-accepted hunk (shows the merged diff vs pre-review)"] = function()
	local path = F.tmp_path()
	seed_two_inserts(path)
	local buf = open_review(path)

	cursor_on(buf, 1)
	press(buf, "<C-x>a") -- accept hunk-1; hunk-2 keeps the review pending
	press(buf, "<C-x>p")

	local lines = popup_lines()
	MiniTest.expect.equality(
		lines[1],
		"hunk 1/2 (accepted)",
		{ fail_reason = "popup header should report the accepted status" }
	)
	MiniTest.expect.equality(lines[2], "+B", { fail_reason = "an accepted insert still differs from pre-review" })
end

-- Placement consistency ----------------------------------------------------

T["popup sits just below the hunk's viewport row in a scrolled buffer"] = function()
	local path = F.tmp_path()
	seed_deep(path)
	local buf = open_review(path)
	local win = Q.win_for_buf(buf)

	cursor_on(buf, 29) -- the L30 line
	child.api.nvim_win_set_cursor(win, { 30, 0 })
	child.cmd("normal! zt") -- buffer line 30 at the viewport top
	press(buf, "<C-x>p")

	local cfg = popup_config()
	MiniTest.expect.equality(#floats(), 1, { fail_reason = "popup should open" })
	MiniTest.expect.equality(
		cfg.row,
		viewport_row_of(win, 29),
		{ fail_reason = "popup's top border should hug the line below the hunk's on-screen row" }
	)
end

T["popup flips above the hunk when there is no room below"] = function()
	local path = F.tmp_path()
	seed_deep(path)
	local buf = open_review(path)
	local win = Q.win_for_buf(buf)

	cursor_on(buf, 29)
	child.api.nvim_win_set_cursor(win, { 4, 0 })
	child.cmd("normal! zt") -- hunk near the viewport bottom
	cursor_on(buf, 29) -- back onto the hunk (still visible, view unchanged)
	press(buf, "<C-x>p")

	local cfg = popup_config()
	local vp = viewport_row_of(win, 29)
	MiniTest.expect.equality(
		cfg.row + cfg.height + 2,
		vp - 1,
		{ fail_reason = "popup's bottom border should sit just above the hunk's on-screen row (flipped)" }
	)
end

T["popup follows its hunk when the window scrolls"] = function()
	local path = F.tmp_path()
	seed_deep(path)
	local buf = open_review(path)
	local win = Q.win_for_buf(buf)

	cursor_on(buf, 29)
	child.api.nvim_win_set_cursor(win, { 20, 0 })
	child.cmd("normal! zt") -- hunk mid-viewport
	cursor_on(buf, 29) -- back onto the hunk (still visible, view unchanged)
	press(buf, "<C-x>p")
	local before = popup_config().row

	child.type_keys("<C-e>", "<C-e>", "<C-e>", "<C-e>", "<C-e>")

	local cfg = popup_config()
	MiniTest.expect.equality(
		cfg.row,
		viewport_row_of(win, 29),
		{ fail_reason = "popup should stay glued to the hunk after scrolling" }
	)
	MiniTest.expect.equality(
		cfg.row < before,
		true,
		{ fail_reason = "scrolling down should move the popup up with the hunk" }
	)
end

T["popup pins to the top edge when its hunk scrolls out of view"] = function()
	local path = F.tmp_path()
	seed_deep(path)
	local buf = open_review(path)
	local win = Q.win_for_buf(buf)

	cursor_on(buf, 29)
	child.api.nvim_win_set_cursor(win, { 30, 0 })
	child.cmd("normal! zt") -- hunk at the very top of the viewport
	press(buf, "<C-x>p")

	child.type_keys("<C-e>") -- hunk scrolls out above

	MiniTest.expect.equality(
		popup_config().row,
		0,
		{ fail_reason = "popup should clamp to the viewport top, not float at a stale row" }
	)
end

T["custom keymaps are honored"] = function()
	local path = F.tmp_path()
	seed_replace(path)
	local buf = open_review(path)

	child.lua([[require("codeforge").config.keymaps.toggle_hunk_diff = "zp"]])
	child.lua(string.format(
		[[require("codeforge.state").get_review(%s):setup_keymaps()]],
		vim.inspect(path)
	))
	cursor_on(buf, 1)
	press(buf, "zp")

	MiniTest.expect.equality(#floats(), 1, { fail_reason = "the custom key should open the hunk popup" })
end
return T
