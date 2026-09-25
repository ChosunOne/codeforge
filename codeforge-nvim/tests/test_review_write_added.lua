do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

-- These tests use REAL on-disk paths on purpose: the behaviour under test is
-- filesystem side effects (directory creation, file creation, refusal to
-- overwrite), which a buffer-only fixture cannot express.

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.lua([[require("codeforge.state").reset(); require("codeforge.state").log_file = nil]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

---A fresh temp directory that does not yet exist, under the child's tmpdir.
---@param suffix? string
---@return string base  a path that is NOT created
local function absent_dir(suffix)
	return child.fn.tempname() .. (suffix or "")
end

---Seed an added-file change at `path` and open its review in the child.
local function open_added(path, lines)
	F.seed_added_file(path, lines)
	child.lua(string.format(
		[[
		_G.path = %s
		require("codeforge.review.buffer").open(path)
		_G.review = require("codeforge.state").get_review(path)
		_G.file = require("codeforge.state").changes[1].files[1]
		_G.change = require("codeforge.state").changes[1]
		]],
		vim.inspect(path)
	))
end

local function read_disk(path)
	local ok = child.fn.filereadable(path)
	if ok == 0 then
		return nil
	end
	return child.fn.readfile(path)
end

-- ── The core feature: accepting an added file creates it on disk ─────────

T["accepting a new file writes it to disk immediately"] = function()
	local dir = absent_dir()
	local path = dir .. "/newfile.lua"
	open_added(path, { "local a = 1", "return a" })

	MiniTest.expect.equality(child.fn.filereadable(path), 0, {
		fail_reason = "precondition: the file must not exist before accepting",
	})

	child.type_keys("<C-x>a")

	MiniTest.expect.equality(child.lua_get([[file.decision]]), "accepted")
	MiniTest.expect.equality(read_disk(path), { "local a = 1", "return a" }, {
		fail_reason = "accepting an added file must write its content to disk",
	})
end

T["accepting a new file into a missing directory creates the parents"] = function()
	-- This is the reported bug: nested directories had to be created by hand.
	local base = absent_dir()
	local path = base .. "/deep/nested/dir/newfile.lua"
	open_added(path, { "hello", "world" })

	MiniTest.expect.equality(child.fn.isdirectory(base), 0, {
		fail_reason = "precondition: the parent must not exist yet",
	})

	child.type_keys("<C-x>a")

	MiniTest.expect.equality(child.fn.isdirectory(base .. "/deep/nested/dir"), 1, {
		fail_reason = "the parent directories must be created",
	})
	MiniTest.expect.equality(read_disk(path), { "hello", "world" })
	MiniTest.expect.equality(child.lua_get([[file.decision]]), "accepted")
end

T["the written file is byte-identical to the reviewed buffer content"] = function()
	-- Accepting must write what the user actually reviewed, including review
	-- edits they made by hand before accepting.
	local base = absent_dir()
	local path = base .. "/edited/newfile.lua"
	open_added(path, { "proposal line" })

	-- Hand-edit the review buffer before accepting.
	child.lua([[
		vim.api.nvim_buf_set_lines(review.buf, 0, -1, false, { "hand edited", "second" })
	]])
	-- The reconcile watcher re-anchors hunk positions from a debounced timer, so
	-- accepting immediately after a hand-edit races it and can miss the hunk
	-- entirely. Wait for the re-anchor before accepting, as a human would.
	child.lua([[vim.wait(300, function() return review:hunk_at_row(0) ~= nil end)]])
	child.type_keys("<C-x>a")

	MiniTest.expect.equality(read_disk(path), { "hand edited", "second" })
end

T["a change with several added files creates every one of them"] = function()
	local base = absent_dir()
	local a = base .. "/pkg/a.lua"
	local b = base .. "/pkg/sub/b.lua"
	open_added(a, { "A" })
	-- Add a sibling added file to the same change.
	child.lua(string.format(
		[[
		local state = require("codeforge.state")
		table.insert(state.changes[1].files, {
			path = %s, status = "added",
			hunks = { { id = "hb", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+B" } } },
		})
		]],
		vim.inspect(b)
	))

	child.type_keys("<C-x>a")
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(b)))
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_pending()]], vim.inspect(b)))

	MiniTest.expect.equality(read_disk(a), { "A" })
	MiniTest.expect.equality(read_disk(b), { "B" }, {
		fail_reason = "a sibling added file must also be written when resolved",
	})
end

-- ── Safety: never overwrite something that already exists ────────────────

T["accepting an added file whose path already exists refuses and reports a failure"] = function()
	local dir = absent_dir()
	child.fn.mkdir(dir, "p")
	local path = dir .. "/existing.lua"
	child.fn.writefile({ "PRECIOUS USER DATA" }, path)

	open_added(path, { "proposal" })
	child.type_keys("<C-x>a")

	MiniTest.expect.equality(read_disk(path), { "PRECIOUS USER DATA" }, {
		fail_reason = "accepting must never overwrite content that already existed",
	})
	-- The part must be reported, not silently skipped.
	local failures = child.lua_get([[file.failures or {}]])
	MiniTest.expect.equality(#failures >= 1, true, {
		fail_reason = "an existing target must be recorded as a per-part failure, got " .. vim.inspect(failures),
	})
	MiniTest.expect.equality(
		child.lua_get([[file.failures[1].reason:find("already exists") ~= nil]]),
		true,
		{ fail_reason = "the failure must name the real reason, got " .. vim.inspect(failures) }
	)
	-- Per the settled lifecycle a failed part keeps its decisions and does NOT
	-- block the change from completing: the decision log records `modified`, so
	-- it cannot claim the file was taken wholesale. Assert that recording.
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0, {
		fail_reason = "the change completes; the failure is carried into the log",
	})
	local entry = child.lua_get([=[require("codeforge.state").log[1]]=])
	MiniTest.expect.equality(entry.status, "modified", {
		fail_reason = "a failed part must make the logged status `modified`, got " .. vim.inspect(entry.status),
	})
	MiniTest.expect.equality(entry.files[1].failures ~= nil, true, {
		fail_reason = "the recorded failure must survive into the decision log",
	})
end

T["a failed added-file write never deletes or truncates the existing file"] = function()
	local dir = absent_dir()
	child.fn.mkdir(dir, "p")
	local path = dir .. "/keep.lua"
	child.fn.writefile({ "one", "two", "three" }, path)

	open_added(path, { "replacement" })
	child.type_keys("<C-x>a")

	MiniTest.expect.equality(read_disk(path), { "one", "two", "three" })
end

-- ── Undo must remove only what we created ───────────────────────────────

T["undoing the accept removes the file CodeForge created"] = function()
	local base = absent_dir()
	local path = base .. "/created/newfile.lua"
	open_added(path, { "content" })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(read_disk(path), { "content" })

	child.lua([[require("codeforge.sidebar.actions").undo()]])

	MiniTest.expect.equality(child.fn.filereadable(path), 0, {
		fail_reason = "undo must remove a file CodeForge itself created",
	})
	MiniTest.expect.equality(child.lua_get([[file.decision]]), vim.NIL)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1, {
		fail_reason = "undo must revive the change",
	})
end

T["undoing an accept that failed does not delete the pre-existing file"] = function()
	local dir = absent_dir()
	child.fn.mkdir(dir, "p")
	local path = dir .. "/existing.lua"
	child.fn.writefile({ "PRECIOUS" }, path)

	open_added(path, { "proposal" })
	child.type_keys("<C-x>a")
	child.lua([[require("codeforge.sidebar.actions").undo()]])

	MiniTest.expect.equality(read_disk(path), { "PRECIOUS" }, {
		fail_reason = "undo must never delete a file CodeForge did not create",
	})
end

T["redo after undo writes the file again"] = function()
	local base = absent_dir()
	local path = base .. "/roundtrip/newfile.lua"
	open_added(path, { "round trip" })

	child.type_keys("<C-x>a")
	MiniTest.expect.equality(read_disk(path), { "round trip" })

	child.lua([[require("codeforge.sidebar.actions").undo()]])
	MiniTest.expect.equality(child.fn.filereadable(path), 0)

	child.lua([[require("codeforge.sidebar.actions").redo()]])
	MiniTest.expect.equality(read_disk(path), { "round trip" }, {
		fail_reason = "redo must recreate the file",
	})
end

-- ── Rejected added files must not be created ────────────────────────────

T["rejecting a new file creates nothing on disk"] = function()
	local base = absent_dir()
	local path = base .. "/rejected/newfile.lua"
	open_added(path, { "content" })
	child.type_keys("<C-x>j")

	MiniTest.expect.equality(child.lua_get([[file.decision]]), "rejected")
	MiniTest.expect.equality(child.fn.filereadable(path), 0, {
		fail_reason = "a rejected added file must not appear on disk",
	})
	MiniTest.expect.equality(child.fn.isdirectory(base), 0, {
		fail_reason = "a rejected added file must not create directories either",
	})
end

-- ── A hand-edited review still writes the reviewed content ──────────────

T["a blank added file is still created on disk"] = function()
	-- Empty content is a legitimate new file, distinct from "nothing written".
	local base = absent_dir()
	local path = base .. "/blank/newfile.lua"
	open_added(path, { "" })
	child.type_keys("<C-x>a")

	MiniTest.expect.equality(child.lua_get([[file.decision]]), "accepted")
	-- An empty new file is a real result, distinct from "nothing written": it
	-- must exist and be genuinely empty (0 bytes, not a lone newline).
	MiniTest.expect.equality(child.fn.filereadable(path), 1, {
		fail_reason = "an accepted empty file must exist on disk",
	})
	MiniTest.expect.equality(child.fn.getfsize(path), 0)
end

T["saving a new file whose parent directory does not exist creates the directories"] = function()
	-- The reported symptom: a new file in a missing directory could not be
	-- written at all (E212), so the directory had to be made by hand. The save
	-- path must create parents too, not just the accept path.
	local base = absent_dir()
	local path = base .. "/nested/newfile.lua"
	open_added(path, { "content" })

	local res = child.lua_get([[ (function()
		local ok, err = pcall(vim.api.nvim_buf_call, review.buf, function() vim.cmd("write") end)
		return { ok = ok, err = tostring(err) }
	end)() ]])
	MiniTest.expect.equality(res.ok, true, { fail_reason = "saving must succeed, got " .. tostring(res.err) })
	MiniTest.expect.equality(read_disk(path), { "content" })
end

T["saving a modified file never creates directories"] = function()
	-- Parent creation is only for a genuinely new path. For an existing-file
	-- review the file is already there, so nothing needs creating: a missing
	-- parent can only mean the file was removed underneath us, which must still
	-- surface as an error rather than being silently recreated.
	local dir = absent_dir()
	child.fn.mkdir(dir, "p")
	local path = dir .. "/gone.lua"
	child.fn.writefile({ "a" }, path)
	F.seed_change(path, { "a" }, { F.replace_hunk("h1", 1, "a", "A") })
	child.lua(string.format(
		[[
		require("codeforge.review.buffer").open(%s)
		_G.review = require("codeforge.state").get_review(%s)
		_G.buf = require("codeforge.state").get_review(%s).buf
		]],
		vim.inspect(path),
		vim.inspect(path),
		vim.inspect(path)
	))

	-- Remove the whole directory while the review is open.
	child.fn.delete(dir, "rf")
	-- Follow test_review_save.lua's pattern: do the pcall inside the child and
	-- stash the outcome in globals. Reading a table straight back trips
	-- mini.test's `v:errmsg` check, because the aborted write sets it.
	child.lua([[
		local ok, err = pcall(vim.api.nvim_buf_call, _G.buf, function() vim.cmd("write") end)
		_G.__wok, _G.__werr = ok, tostring(err)
	]])
	MiniTest.expect.equality(child.lua_get([[_G.__wok]]), false, {
		fail_reason = "a modified file whose directory vanished must not be silently recreated",
	})
	MiniTest.expect.equality(child.fn.isdirectory(dir), 0, {
		fail_reason = "no directory may be created for a modified file",
	})
end

return T
