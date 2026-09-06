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
	return F.hunk_outcome(path, hunk_id)
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

---Capture vim.notify calls in the child for assertion.
local function capture_notify()
	child.lua(
		[[CODEFORGE_NOTES = {}; vim.notify = function(msg, level) table.insert(CODEFORGE_NOTES, { msg = msg, level = level }) end]]
	)
end

local function notify_msgs()
	return child.lua_get([[CODEFORGE_NOTES or {}]])
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

T["sweep decides undecided atomic files; decided ones stay put"] = function()
	local OA = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(OA, pa)
	local added = F.tmp_path()
	local deleted = F.tmp_path()
	local deleted2 = F.tmp_path()
	child.fn.writefile({ "gone" }, deleted)
	child.fn.writefile({ "gone2" }, deleted2)
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
                                { path = %s, status = "deleted", hunks = {}, decision = "rejected" },
                        },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
			vim.inspect(pa),
			vim.inspect(OA),
			vim.inspect(F.replace_hunk("a-h1", 2, "a2", "A2")),
			vim.inspect(added),
			vim.inspect(deleted),
			vim.inspect(deleted2)
		)
	)

	child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(hunk_status(pa, "a-h1"), "accepted", { fail_reason = "modified file swept" })
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(added))),
		true,
		{ fail_reason = "no review should be created for the added file" }
	)
	-- the sweep triaged everything -> the change auto-completed; the decision
	-- outcomes live in the newest decision-log entry now
	local entry = child.lua_get([=[require("codeforge.state").log[#require("codeforge.state").log]]=])
	MiniTest.expect.equality(entry.files[2].decision, "accepted", {
		fail_reason = "undecided added file should be accepted by the sweep, got " .. vim.inspect(entry.files[2]),
	})
	MiniTest.expect.equality(entry.files[3].decision, "accepted", {
		fail_reason = "undecided deleted file should be accepted by the sweep",
	})
	MiniTest.expect.equality(entry.files[4].decision, "rejected", {
		fail_reason = "already-decided atomic file must keep its decision",
	})

	-- reject phase: a fresh change with an undecided atomic flips to rejected
	local pb = F.tmp_path()
	local added2 = F.tmp_path()
	child.fn.writefile({ "b1", "b2" }, pb)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-002",
                        title = "Atomic2",
                        files = {
                                { path = %s, status = "modified", base = { "b1", "b2" }, hunks = { %s } },
                                { path = %s, status = "added", hunks = {} },
                        },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-002"
        ]],
		vim.inspect(pb),
		vim.inspect(F.replace_hunk("b-h1", 1, "b1", "B1")),
		vim.inspect(added2)
	))
	child.lua_get([[require("codeforge.sidebar.actions").reject_pending()]])
	entry = child.lua_get([=[require("codeforge.state").log[#require("codeforge.state").log]]=])
	MiniTest.expect.equality(entry.files[2].decision, "rejected", {
		fail_reason = "reject sweep should decide the added file as rejected",
	})
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

T["sweep notifies when conflicted hunks remain after sweeping"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	-- pre-edit U region of h1 (conflict source, same recipe as the sandbox)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, { "a", "b-user", "c", "d" })
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	open_review(path)
	-- mark h1 conflicted (as the resolve flow would have left it)
	child.lua(
		string.format([[require("codeforge.state").get_review(%s).hunk_status.h1 = "conflicted"]], vim.inspect(path))
	)
	capture_notify()

	local swept = child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(swept, 1, { fail_reason = "only h2 (pending) should be swept" })
	local msgs = notify_msgs()
	local conflict_msg
	for _, m in ipairs(msgs) do
		if tostring(m.msg):find("conflict") then
			conflict_msg = m.msg
		end
	end
	MiniTest.expect.equality(conflict_msg ~= nil, true, {
		fail_reason = "a conflict summary should be notified, got " .. vim.inspect(msgs),
	})
	MiniTest.expect.equality(
		tostring(conflict_msg):find("1 hunk") ~= nil,
		true,
		{ fail_reason = "message should count the conflicted hunk, got: " .. tostring(conflict_msg) }
	)
	MiniTest.expect.equality(
		tostring(conflict_msg):find("resolve") ~= nil,
		true,
		{ fail_reason = "message should suggest resolving, got: " .. tostring(conflict_msg) }
	)
end

T["clean sweep does not notify"] = function()
	local O = { "a", "b" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	F.seed_change(path, O, { F.replace_hunk("h1", 1, "a", "A") })
	open_review(path)
	capture_notify()

	child.lua_get([[require("codeforge.sidebar.actions").accept_pending()]])

	MiniTest.expect.equality(#notify_msgs(), 0, {
		fail_reason = "a fully-clean sweep should stay silent, got " .. vim.inspect(notify_msgs()),
	})
end

T["reject_pending sweeps conflicted hunks back to the user's version (U)"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	-- user edited the region h1 touches BEFORE review (U != O)
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, -1, false, { "a", "b-user", "c", "d" })
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	open_review(path)
	-- h1 went conflicted (as an earlier accept attempt would leave it)
	child.lua(
		string.format([[require("codeforge.state").get_review(%s).hunk_status.h1 = "conflicted"]], vim.inspect(path))
	)

	child.lua(string.format([[require("codeforge.state").get_review(%s):reject_pending()]], vim.inspect(path)))

	MiniTest.expect.equality(hunk_status(path, "h1"), "rejected", {
		fail_reason = "a conflicted hunk must be sweepable by reject (take ours)",
	})
	MiniTest.expect.equality(hunk_status(path, "h2"), "rejected", { fail_reason = "pending h2 should be swept too" })
	Q.expect_lines(
		"buffer after reject sweep of conflict",
		buf_lines(path),
		{ "a", "b-user", "c", "d" },
		"user's U content must be restored, not O"
	)
end

return T
