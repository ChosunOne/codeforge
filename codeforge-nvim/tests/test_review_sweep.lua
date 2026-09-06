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

local function buf_lines(path)
	local b = Q.find_buf(path)
	if not b then
		return nil
	end
	return child.api.nvim_buf_get_lines(b, 0, -1, false)
end

---Seed a change with several modified files; `files` is a list of
---{ path, base, hunks } tables (all real temp-file paths).
local function seed_multi(files, sel)
	local chunks = {}
	for i, f in ipairs(files) do
		chunks[#chunks + 1] = string.format(
			[[{ path = %s, status = "modified", base = %s, hunks = %s }]],
			vim.inspect(f.path),
			vim.inspect(f.base),
			vim.inspect(f.hunks)
		)
	end
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "Sweep",
                        files = { %s },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		table.concat(chunks, ", ")
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

-- ── Review-level sweep ────────────────────────────────────────────────────

T["accept_pending accepts every pending hunk, surviving row shifts"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	-- h1 inserts two lines (shifting everything below), h2 replaces later on
	local h1 = F.insert_hunk("hunk-ins", 2, { "X", "Y" })
	local h2 = F.replace_hunk("hunk-rep", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_pending()]], vim.inspect(path)))

	MiniTest.expect.equality(hunk_status(path, "hunk-ins"), "accepted", { fail_reason = "h1 should be accepted" })
	MiniTest.expect.equality(hunk_status(path, "hunk-rep"), "accepted", { fail_reason = "h2 should be accepted" })
	Q.expect_lines("buffer after sweep", buf_lines(path), { "a", "X", "Y", "b", "c", "D", "e" })
end

T["accept_pending leaves already-triaged hunks alone"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	-- triage h1 as rejected via the row-based path
	local row = child.lua(
		string.format(
			[[local r = require("codeforge.state").get_review(%s); return r:hunk_row("h1")]],
			vim.inspect(path)
		)
	)
	child.api.nvim_win_set_cursor(child.api.nvim_get_current_win(), { 1, 0 })
	child.lua(string.format([[require("codeforge.state").get_review(%s):reject_hunk(%d)]], vim.inspect(path), row - 1))

	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_pending()]], vim.inspect(path)))

	MiniTest.expect.equality(hunk_status(path, "h1"), "rejected", { fail_reason = "h1 must stay rejected" })
	MiniTest.expect.equality(hunk_status(path, "h2"), "accepted", { fail_reason = "h2 should be accepted" })
	Q.expect_lines("buffer after mixed sweep", buf_lines(path), { "a", "b", "c", "D", "e" })
end

T["reject_pending restores every pending hunk region"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.insert_hunk("h1", 2, { "X" })
	local h2 = F.replace_hunk("h2", 3, "c", "C")
	F.seed_change(path, O, { h1, h2 })

	open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):reject_pending()]], vim.inspect(path)))

	MiniTest.expect.equality(hunk_status(path, "h1"), "rejected", { fail_reason = "h1 should be rejected" })
	MiniTest.expect.equality(hunk_status(path, "h2"), "rejected", { fail_reason = "h2 should be rejected" })
	Q.expect_lines("buffer after reject sweep", buf_lines(path), O)
end

T["accept_pending marks conflicting hunks conflicted and still sweeps the rest"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	-- user edits the region h1 touches before review starts
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, { "a", "b-user", "c", "d" })
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	open_review(path)
	-- user hand-edits the proposal region of h1 differently -> 3-way conflict
	local b = Q.find_buf(path)
	child.api.nvim_buf_set_lines(b, 1, 2, false, { "B-user2" })

	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_pending()]], vim.inspect(path)))

	MiniTest.expect.equality(hunk_status(path, "h1"), "conflicted", { fail_reason = "h1 should be conflicted" })
	MiniTest.expect.equality(hunk_status(path, "h2"), "accepted", { fail_reason = "h2 should still be swept" })
end

-- ── Change-scoped sweep (sidebar actions) ─────────────────────────────────

T["actions.accept_pending resolves files not under review headlessly"] = function()
	local OA = { "a1", "a2", "a3" }
	local OB = { "b1", "b2" }
	local pa, pb = F.tmp_path(), F.tmp_path()
	child.fn.writefile(OA, pa)
	child.fn.writefile(OB, pb)
	seed_multi({
		{ path = pa, base = OA, hunks = { F.replace_hunk("a-h1", 2, "a2", "A2") } },
		{ path = pb, base = OB, hunks = { F.replace_hunk("b-h1", 1, "b1", "B1") } },
	}, 1)

	local swept = child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(swept, 2, { fail_reason = "two hunks should be swept, got " .. tostring(swept) })
	MiniTest.expect.equality(hunk_status(pa, "a-h1"), "accepted", { fail_reason = "a-h1 accepted" })
	MiniTest.expect.equality(hunk_status(pb, "b-h1"), "accepted", { fail_reason = "b-h1 accepted" })
	Q.expect_lines("file A buffer", buf_lines(pa), { "a1", "A2", "a3" })
	Q.expect_lines("file B buffer", buf_lines(pb), { "B1", "b2" })
end

T["actions.reject_pending headlessly restores unreviewed buffers"] = function()
	local OA = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(OA, pa)
	seed_multi({
		{ path = pa, base = OA, hunks = { F.replace_hunk("a-h1", 1, "a1", "A1") } },
	}, 1)

	child.lua_get([[require("codeforge.sidebar.actions").reject_pending()]])

	MiniTest.expect.equality(hunk_status(pa, "a-h1"), "rejected", { fail_reason = "a-h1 rejected" })
	Q.expect_lines("file A buffer untouched", buf_lines(pa), OA)
end

T["actions sweep mixes live reviews with headless files"] = function()
	local OA = { "a1", "a2" }
	local OB = { "b1", "b2" }
	local pa, pb = F.tmp_path(), F.tmp_path()
	child.fn.writefile(OA, pa)
	child.fn.writefile(OB, pb)
	seed_multi({
		{ path = pa, base = OA, hunks = { F.replace_hunk("a-h1", 2, "a2", "A2") } },
		{ path = pb, base = OB, hunks = { F.replace_hunk("b-h1", 1, "b1", "B1") } },
	}, 1)

	open_review(pa) -- only A is under review
	child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(hunk_status(pa, "a-h1"), "accepted", { fail_reason = "live review swept" })
	MiniTest.expect.equality(hunk_status(pb, "b-h1"), "accepted", { fail_reason = "headless file swept" })
	Q.expect_lines("file A buffer", buf_lines(pa), { "a1", "A2" })
	Q.expect_lines("file B buffer", buf_lines(pb), { "B1", "b2" })
end

T["sweep skips atomic files entirely"] = function()
	local OA = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(OA, pa)
	local added = F.tmp_path()
	local deleted = F.tmp_path()
	child.fn.writefile({ "gone" }, deleted)
	child.lua(
		string.format(
			[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "Atomic",
                        files = {
                                { path = %s, status = "modified", base = %s, hunks = { %s } },
                                { path = %s, status = "added", hunks = {} },
                                { path = %s, status = "deleted", hunks = {} },
                        },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
			vim.inspect(pa),
			vim.inspect(OA),
			vim.inspect(F.replace_hunk("a-h1", 2, "a2", "A2")),
			vim.inspect(added),
			vim.inspect(deleted)
		)
	)

	child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(hunk_status(pa, "a-h1"), "accepted", { fail_reason = "modified file swept" })
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(added))),
		true,
		{ fail_reason = "no review should be created for the added file" }
	)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(deleted))),
		true,
		{ fail_reason = "no review should be created for the deleted file" }
	)
end

T["sweep on a fully triaged change is a no-op returning zero"] = function()
	local OA = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(OA, pa)
	seed_multi({
		{ path = pa, base = OA, hunks = { F.replace_hunk("a-h1", 1, "a1", "A1") } },
	}, 1)
	child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	local again = child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(again, 0, { fail_reason = "nothing pending, nothing swept" })
end

return T
