---Edits to a hunk before triage: the hunk must stay interactive.
---Regression coverage for "edit a hunk, then lose the ability to accept/reject it":
---`_reconcile` used to treat an in-place content edit the same as a line
---deletion, strip the placement's signs, and leave the hunk unlocatable — so
---accept/reject/next-hunk silently did nothing.
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

---Is hunk `hunk_id` still locatable from the buffer rows it spans?
local function hunk_reachable(path, hunk_id)
	return child.lua_get(string.format(
		[[(function()
			local r = require("codeforge.state").get_review(%s)
			if not r then return false end
			return r:hunk_row(%s) ~= nil
		end)()]],
		vim.inspect(path),
		vim.inspect(hunk_id)
	))
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

T["editing a modified line keeps the hunk pending and accept works"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	Q.expect_lines("proposal P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })

	-- The user amends the proposal line in place, then the debounce reconciles.
	child.api.nvim_buf_set_lines(buf, 1, 2, false, { "B edited" })
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(
		hunk_reachable(path, "h1"),
		true,
		{ fail_reason = "an in-place edit must not make the hunk unlocatable (hunk_row went nil)" }
	)
	MiniTest.expect.equality(
		child.lua_get(
			string.format([[require("codeforge.state").get_review(%s):hunk_at_row(1) ~= nil]], vim.inspect(path))
		),
		true,
		{ fail_reason = "the edited row must still resolve to its hunk" }
	)

	-- Accept must actually handle the hunk (status changes), not silently no-op.
	child.lua(string.format(
		[[
                local r = require("codeforge.state").get_review(%s)
                r:accept_hunk(1)
        ]],
		vim.inspect(path)
	))
	-- The hunk must be resolved as accepted, whether the review is still live or
	-- the change auto-completed (F.hunk_outcome reads whichever is authoritative).
	MiniTest.expect.equality(F.hunk_outcome(path, "h1"), "accepted", {
		fail_reason = "accept_hunk on an edited hunk must resolve it as accepted",
	})
	-- The user's edit is preserved in the buffer.
	MiniTest.expect.equality(vim.tbl_contains(child.api.nvim_buf_get_lines(buf, 0, -1, false), "B edited"), true, {
		fail_reason = "the amended line must survive acceptance, got "
			.. vim.inspect(child.api.nvim_buf_get_lines(buf, 0, -1, false)),
	})
end

T["editing a modified line keeps the hunk pending and reject works"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.api.nvim_buf_set_lines(buf, 1, 2, false, { "B edited" })
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(hunk_reachable(path, "h1"), true, {
		fail_reason = "the hunk must stay locatable after an in-place edit",
	})

	child.lua(string.format(
		[[
                local r = require("codeforge.state").get_review(%s)
                r:reject_hunk(1)
        ]],
		vim.inspect(path)
	))

	-- A reject restores the pre-review text U for that region.
	MiniTest.expect.equality(F.hunk_outcome(path, "h1"), "rejected", {
		fail_reason = "reject_hunk on an edited hunk must resolve it as rejected",
	})
	MiniTest.expect.equality(
		vim.tbl_contains(child.api.nvim_buf_get_lines(buf, 0, -1, false), "b"),
		true,
		{ fail_reason = "rejecting must restore the original line 'b'" }
	)
end

T["editing a modified line keeps the sign visible on that row"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	local n = child.lua_get([[require("codeforge.review.diff").namespace]])
	MiniTest.expect.equality(Q.sign_at(buf, n, 1) ~= nil, true, {
		fail_reason = "precondition: the modified line carries a sign before the edit",
	})

	child.api.nvim_buf_set_lines(buf, 1, 2, false, { "B edited" })
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(
		Q.sign_at(buf, n, 1) ~= nil,
		true,
		{ fail_reason = "the sign must remain on the edited line (content edit, not a deletion)" }
	)
	MiniTest.expect.equality(
		Q.sign_at(buf, n, 1).sign_hl_group,
		"CodeForgeHunkModified",
		{ fail_reason = "the surviving sign must keep its Modified styling" }
	)
end

T["editing an added line keeps the hunk interactive"] = function()
	local O = { "a", "b" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.insert_hunk("h-add", 2, { "Z" }) })

	local buf = open_review(path)
	Q.expect_lines("proposal P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "Z", "b" })

	child.api.nvim_buf_set_lines(buf, 1, 2, false, { "Z amended" })
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(hunk_reachable(path, "h-add"), true, {
		fail_reason = "an amended inserted line must keep its hunk locatable",
	})
	child.lua(string.format(
		[[
                require("codeforge.state").get_review(%s):accept_hunk(1)
        ]],
		vim.inspect(path)
	))
	local final = child.api.nvim_buf_get_lines(buf, 0, -1, false)
	MiniTest.expect.equality(vim.tbl_contains(final, "Z amended"), true, {
		fail_reason = "accepting must keep the amended text, got " .. vim.inspect(final),
	})
end

T["deleting a hunk's line still drops its sign (deletion is not an amendment)"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	local n = child.lua_get([[require("codeforge.review.diff").namespace]])

	child.api.nvim_buf_set_lines(buf, 1, 2, false, {})
	child.lua([[vim.wait(400)]])

	Q.expect_lines("deleted", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "c" })
	local signs = child.lua_get(
		string.format(
			[[#vim.tbl_filter(function(m) return m[4] and m[4].sign_text end, vim.api.nvim_buf_get_extmarks(%d, %d, 0, -1, {}))]],
			buf,
			n
		)
	)
	MiniTest.expect.equality(signs, 0, {
		fail_reason = "a genuine line deletion must not leave a stale sign behind",
	})
end

T["unrelated edits elsewhere do not disturb an untouched hunk"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	-- insert far above the hunk: it should shift and stay pending
	child.api.nvim_buf_set_lines(buf, 0, 0, false, { "header" })
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(hunk_reachable(path, "h1"), true, {
		fail_reason = "an unrelated insertion must not orphan the hunk",
	})
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s):hunk_row("h1")]], vim.inspect(path))),
		3,
		{ fail_reason = "the hunk's row should shift down by the inserted line (1-indexed 3)" }
	)
end

-- ── Adversarial: distinguishing an amendment from a deletion ──────────────

T["a multi-line hunk survives editing one line and deleting another"] = function()
	local O = { "a", "x", "y", "b" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	-- 2-line modify: x,y -> X,Y (both lines signed)
	local hunk = {
		id = "h-multi",
		old_start = 2,
		old_lines = 2,
		new_start = 2,
		new_lines = 2,
		lines = { "-x", "-y", "+X", "+Y" },
	}
	F.seed_change(path, O, { hunk })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "X", "Y", "b" })

	-- amend the first modified line, delete the second
	child.api.nvim_buf_set_lines(buf, 1, 2, false, { "X amended" })
	child.api.nvim_buf_set_lines(buf, 2, 3, false, {})
	child.lua([[vim.wait(400)]])

	Q.expect_lines("after amend+delete", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "X amended", "b" })
	-- The hunk must remain locatable through the surviving amended line, so the
	-- user can still accept or reject the whole hunk.
	MiniTest.expect.equality(hunk_reachable(path, "h-multi"), true, {
		fail_reason = "a partially-amended hunk must stay locatable so it can still be triaged",
	})
	child.lua(string.format(
		[[
                require("codeforge.state").get_review(%s):accept_hunk(1)
        ]],
		vim.inspect(path)
	))
	MiniTest.expect.equality(F.hunk_outcome(path, "h-multi"), "accepted", {
		fail_reason = "the partially-amended hunk must be acceptable",
	})
end

T["clearing a hunk's lines leaves it triageable at the deletion boundary"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.api.nvim_buf_set_lines(buf, 1, 2, false, {})
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(hunk_reachable(path, "h1"), true, {
		fail_reason = "a fully emptied hunk must stay locatable so it can still be triaged",
	})
	local adds = child.lua_get(
		string.format([[require("codeforge.state").get_review(%s).placements[1].adds]], vim.inspect(path))
	)
	MiniTest.expect.equality(adds, {}, {
		fail_reason = "an emptied hunk must have no added lines, got " .. vim.inspect(adds),
	})
end

T["accepting a fully emptied hunk keeps the deletion and resolves it"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.api.nvim_buf_set_lines(buf, 1, 2, false, {})
	child.lua([[vim.wait(400)]])

	-- Accept by the hunk's own anchor row, exactly as the :hunk_at_row dispatch does.
	child.lua(string.format(
		[[
                local r = require("codeforge.state").get_review(%s)
                r:accept_hunk(r:hunk_row("h1") - 1)
        ]],
		vim.inspect(path)
	))

	MiniTest.expect.equality(F.hunk_outcome(path, "h1"), "accepted", {
		fail_reason = "accepting an emptied hunk must resolve it, not silently no-op",
	})
	MiniTest.expect.equality(child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "c" }, {
		fail_reason = "accepting keeps the user's deletion of the hunk's lines",
	})
end

T["rejecting a fully emptied hunk restores the pre-review text"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.api.nvim_buf_set_lines(buf, 1, 2, false, {})
	child.lua([[vim.wait(400)]])

	child.lua(string.format(
		[[
                local r = require("codeforge.state").get_review(%s)
                r:reject_hunk(r:hunk_row("h1") - 1)
        ]],
		vim.inspect(path)
	))

	MiniTest.expect.equality(F.hunk_outcome(path, "h1"), "rejected", {
		fail_reason = "rejecting an emptied hunk must resolve it as rejected",
	})
	MiniTest.expect.equality(child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "b", "c" }, {
		fail_reason = "rejecting restores the pre-review text for the region",
	})
end

T["a fully emptied inserted hunk stays triageable"] = function()
	-- A pure insertion has no deletion fold either, so clearing its only line
	-- orphaned it the same way the replace case was orphaned.
	local O = { "a", "b" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.insert_hunk("h-add", 2, { "Z" }) })

	local buf = open_review(path)
	child.api.nvim_buf_set_lines(buf, 1, 2, false, {})
	child.lua([[vim.wait(400)]])

	MiniTest.expect.equality(hunk_reachable(path, "h-add"), true, {
		fail_reason = "an emptied insertion must stay locatable",
	})
	child.lua(string.format(
		[[
                local r = require("codeforge.state").get_review(%s)
                r:reject_hunk(r:hunk_row("h-add") - 1)
        ]],
		vim.inspect(path)
	))
	MiniTest.expect.equality(F.hunk_outcome(path, "h-add"), "rejected", {
		fail_reason = "the emptied insertion must be rejectable",
	})
end

T["next_hunk reaches a fully emptied hunk"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	child.api.nvim_buf_set_lines(buf, 1, 2, false, {})
	child.lua([[vim.wait(400)]])

	child.api.nvim_win_set_cursor(0, { 1, 0 })
	child.lua(string.format([[require("codeforge.state").get_review(%s):next_hunk()]], vim.inspect(path)))
	MiniTest.expect.equality(child.api.nvim_win_get_cursor(0)[1], 2, {
		fail_reason = "next_hunk must land on the emptied hunk's boundary row",
	})
end

T["editing a context line does not make an untouched hunk appear amended"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })

	local buf = open_review(path)
	-- edit a line outside the hunk's signed row
	child.api.nvim_buf_set_lines(buf, 2, 3, false, { "c changed" })
	child.lua([[vim.wait(400)]])

	-- hunk still lives on row idx 1, and its recorded content is unchanged
	local contents = child.lua_get(
		string.format([[require("codeforge.state").get_review(%s).placements[1].add_contents]], vim.inspect(path))
	)
	MiniTest.expect.equality(contents[1], "B", {
		fail_reason = "editing an unrelated line must not rewrite the hunk's recorded content, got "
			.. vim.inspect(contents),
	})
end

return T
