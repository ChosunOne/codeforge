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

local O = { "a", "b", "c", "d", "e" }
local HUNKS = { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") }

local session_file

---Point CodeForge at a private session file and drop the in-memory log path.
---Uses the *parent's* tempname: `child.restart` wipes the child's temp dir, and
---the setup() test must survive a restart to prove restore works.
local function use_temp_session()
	session_file = vim.fn.tempname() .. ".json"
	child.lua(string.format(
		[[
			require("codeforge.session").configure(%q)
			require("codeforge.state").log_file = nil
		]],
		session_file
	))
end

---Seed one modified change with a live review carrying triage.
local function seed_reviewed()
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.changes = { {
				id = "change-001",
				title = "Persisted change",
				timestamp = 123,
				files = { { path = %s, status = "modified", base = %s, hunks = %s } },
			} }
			state.current_change_index = 1
			state.current_change_id = "change-001"
			state.reviews[%s] = {
				hunk_status = { h1 = "accepted", h2 = "rejected" },
				user_modified = true,
				expanded = { h2 = true },
			}
		]],
		vim.inspect(path),
		vim.inspect(O),
		vim.inspect(HUNKS),
		vim.inspect(path)
	))
	return path
end

---Simulate a fresh Neovim: forget all in-memory review state, then load.
local function restart()
	child.lua([[require("codeforge.state").reset()]])
	child.lua([[require("codeforge.session").load()]])
end

local function session_json()
	local f = io.open(session_file, "r")
	if not f then
		return nil
	end
	local raw = f:read("*a")
	f:close()
	local ok, decoded = pcall(vim.json.decode, raw)
	return ok and decoded or "__unparseable__"
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			use_temp_session()
		end,
		post_case = function()
			F.cleanup()
			if session_file then
				os.remove(session_file)
			end
		end,
		post_once = child.stop,
	},
})

T["a saved session restores tracked changes with their base and hunks"] = function()
	local path = seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	restart()

	local change = child.lua_get([=[require("codeforge.state").changes[1]]=])
	MiniTest.expect.equality(change.id, "change-001")
	MiniTest.expect.equality(change.title, "Persisted change")
	MiniTest.expect.equality(change.files[1].path, path)
	MiniTest.expect.equality(change.files[1].base, O)
	MiniTest.expect.equality(change.files[1].hunks[1].id, "h1")
	MiniTest.expect.equality(change.files[1].hunks[2].lines, HUNKS[2].lines)
end

T["restoring the change set is silent: no buffer is opened"] = function()
	local path = seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	local before = child.lua_get([[vim.api.nvim_list_bufs()]])
	restart()

	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(vim.api.nvim_list_bufs(), {}) == false]]), true)
	local reviews = child.lua_get([[require("codeforge.state").reviews]])
	MiniTest.expect.equality(reviews, vim.empty_dict())
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) == nil]], vim.inspect(path))),
		true
	)
	MiniTest.expect.equality(type(before), "table")
end

T["decisions survive a restart: hunk outcomes and hand-edit flag are restored"] = function()
	local path = seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	restart()

	-- Triage is readable without opening the review at all.
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h1")]], vim.inspect(path))),
		"accepted"
	)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h2")]], vim.inspect(path))),
		"rejected"
	)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").review_modified(%s)]], vim.inspect(path))),
		true
	)
end

T["a restored change reports its derived status, not pending"] = function()
	local path = seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	restart()

	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").derive_status(require("codeforge.state").changes[1])]]),
		"modified"
	)
	-- The sidebar must agree with the derived status before any review opens.
	local glyph = child.lua_get(
		string.format(
			[[{require("codeforge.state").file_status_glyph(require("codeforge.state").changes[1].files[1])}]],
			vim.inspect(path)
		)
	)
	MiniTest.expect.equality(glyph[1], "●")
end

T["selection, expansion and fold state survive a restart"] = function()
	local path = seed_reviewed()
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.expanded_files["change-001"] = { [%s] = true }
		]],
		vim.inspect(path)
	))
	child.lua([[require("codeforge.session").save()]])
	restart()

	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").current_change_id]]), "change-001")
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").is_expanded(%s)]], vim.inspect(path))),
		true
	)
end

T["atomic file decisions and part failures survive a restart"] = function()
	local added = F.tmp_path()
	local modified = F.tmp_path()
	child.fn.writefile(O, modified)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.changes = { {
				id = "change-002",
				title = "Mixed",
				files = {
					{ path = %s, status = "added", hunks = { { id = "a1", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+new" } } }, decision = "accepted", atomic_baseline = {} },
					{ path = %s, status = "modified", base = %s, hunks = %s, failures = { { reason = "target is not readable", at = 7 } } },
				},
			} }
			state.current_change_index = 1
			state.current_change_id = "change-002"
		]],
		vim.inspect(added),
		vim.inspect(modified),
		vim.inspect(O),
		vim.inspect(HUNKS)
	))
	child.lua([[require("codeforge.session").save()]])
	restart()

	local change = child.lua_get([=[require("codeforge.state").changes[1]]=])
	MiniTest.expect.equality(change.files[1].decision, "accepted")
	-- No failures key at all: an absent field, not a JSON null.
	MiniTest.expect.equality(change.files[1].failures, nil)
	MiniTest.expect.equality(change.files[2].failures[1].reason, "target is not readable")
	-- A transient pre-review baseline is not session state: undo history dies
	-- with the process, so restoring it would be a lie.
	MiniTest.expect.equality(change.files[1].atomic_baseline, nil)
end

T["completed changes are not resurrected by a restart"] = function()
	local path = seed_reviewed()
	child.lua([[
		local state = require("codeforge.state")
		state.completed["change-001"] = { change = state.changes[1], reviews = {}, entry = { id = "change-001" } }
		state.completed_order = { "change-001" }
		state.changes = {}
		state.current_change_index = nil
		state.current_change_id = nil
		require("codeforge.session").save()
	]])
	restart()

	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").completed_order]]), vim.empty_dict())
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
end

T["a missing session file restores nothing and does not error"] = function()
	os.remove(session_file)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.session").load()]]), 0)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
end

T["a corrupt or untrusted session file is refused instead of half-restored"] = function()
	local path = seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	os.remove(session_file)
	local f = io.open(session_file, "w")
	f:write('{"version":1,"changes":[{"id":"x","files":[{}]}]}') -- structurally unusable
	f:close()
	child.lua([[require("codeforge.state").reset()]])
	MiniTest.expect.equality(child.lua_get([[require("codeforge.session").load()]]), 0)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h1")]], vim.inspect(path))),
		vim.NIL
	)
end

T["an unknown snapshot version is refused rather than guessed at"] = function()
	seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	local decoded = session_json()
	decoded.version = 999
	local f = io.open(session_file, "w")
	f:write(vim.json.encode(decoded))
	f:close()
	child.lua([[require("codeforge.state").reset()]])
	MiniTest.expect.equality(child.lua_get([[require("codeforge.session").load()]]), 0)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
end

T["loading never clobbers changes already tracked in this session"] = function()
	seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	-- A live change set exists (e.g. a second load, or a race with publish).
	child.lua([[require("codeforge.session").load()]])
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
	child.lua([[require("codeforge.session").load()]])
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
end

T["saving is skipped and nothing is written when persistence is off"] = function()
	local path = seed_reviewed()
	child.lua([[require("codeforge.session").configure(false)]])
	child.lua([[require("codeforge.session").save()]])
	MiniTest.expect.equality(session_json(), nil)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.session").enabled()]]), false)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h1")]], vim.inspect(path))),
		"accepted"
	)
end

T["state changes persist write-through without an explicit save"] = function()
	seed_reviewed()
	child.lua([[require("codeforge.session").attach()]])
	MiniTest.expect.equality(session_json(), nil)
	-- A triage transition notifies state; that must reach disk on its own.
	child.lua([[require("codeforge.state").notify_change()]])
	MiniTest.expect.equality(type(session_json()), "table")
end

T["consistent state is not rewritten"] = function()
	seed_reviewed()
	child.lua([[require("codeforge.session").save()]])
	local first = child.lua_get([[vim.uv.fs_stat(require("codeforge.session").path()).mtime.sec]])
	child.lua([[vim.wait(1100)]])
	child.lua([[require("codeforge.session").save()]])
	-- Same serializable state: no pointless disk write on every notify.
	MiniTest.expect.equality(child.lua_get([[vim.uv.fs_stat(require("codeforge.session").path()).mtime.sec]]), first)
end

T["opening a restored review replays accepted and rejected decisions onto the buffer"] = function()
	local path = seed_reviewed()
	-- The pre-review content `U` is what is on disk; the restored decisions were
	-- made against exactly this.
	child.fn.writefile(O, path)
	child.lua([[require("codeforge.session").save()]])
	restart()

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	local buf = Q.find_buf(path)
	MiniTest.expect.equality(
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		-- h1 accepted keeps the proposal (B); h2 rejected falls back to U (d).
		{ "a", "B", "c", "d", "e" }
	)
	local review = child.lua_get(
		string.format([[{ (require("codeforge.state").get_review(%s) or {}).user_modified }]], vim.inspect(path))
	)
	-- The hand-edit flag is descriptive, not a buffer state: it must survive
	-- replay untouched.
	MiniTest.expect.equality(review[1], true)
end

T["a restored pending deletion fold keeps its expansion state"] = function()
	local path = F.tmp_path()
	local base = { "a", "b", "c", "d" }
	child.fn.writefile(base, path)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.changes = { {
				id = "change-001",
				title = "Fold",
				files = { { path = %s, status = "modified", base = %s, hunks = %s } },
			} }
			state.current_change_index = 1
			state.current_change_id = "change-001"
			-- Undecided deletion hunk whose fold the user had expanded.
			state.reviews[%s] = { hunk_status = {}, expanded = { h1 = true } }
		]],
		vim.inspect(path),
		vim.inspect(base),
		vim.inspect({ F.delete_hunk("h1", 2, { "b" }) }),
		vim.inspect(path)
	))
	child.lua([[require("codeforge.session").save()]])
	restart()

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	MiniTest.expect.equality(
		child.lua_get(
			string.format([[(require("codeforge.state").get_review(%s) or {}).expanded.h1 == true]], vim.inspect(path))
		),
		true
	)
end

T["a genuinely pending hunk stays pending after a restore and keeps the proposal"] = function()
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.changes = { {
				id = "change-001",
				title = "Half done",
				files = { { path = %s, status = "modified", base = %s, hunks = %s } },
			} }
			state.current_change_index = 1
			state.current_change_id = "change-001"
			state.reviews[%s] = { hunk_status = { h1 = "accepted" }, expanded = {} }
		]],
		vim.inspect(path),
		vim.inspect(O),
		vim.inspect(HUNKS),
		vim.inspect(path)
	))
	child.lua([[require("codeforge.session").save()]])
	restart()

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	local buf = Q.find_buf(path)
	MiniTest.expect.equality(
		child.api.nvim_buf_get_lines(buf, 0, -1, false),
		-- h1 decided (B), h2 still pending so it shows the proposal (D).
		{ "a", "B", "c", "D", "e" }
	)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h2")]], vim.inspect(path))),
		vim.NIL
	)
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").derive_status(require("codeforge.state").changes[1])]]),
		"pending"
	)
end

T["opening a restored review neither logs nor completes the change"] = function()
	local path = seed_reviewed()
	child.fn.writefile(O, path)
	child.lua([[require("codeforge.session").save()]])
	restart()

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	child.lua([[vim.wait(200)]])

	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").completed_order]]), 0)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
end

T["decisions made after a restore persist in turn"] = function()
	local path = seed_reviewed()
	child.fn.writefile(O, path)
	child.lua([[require("codeforge.session").save()]])
	restart()

	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	child.lua([[require("codeforge.session").save()]])

	-- Round-trip once more: h2's rejection must still be there.
	child.lua([[require("codeforge.state").reset()]])
	child.lua([[require("codeforge.session").load()]])
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h2")]], vim.inspect(path))),
		"rejected"
	)
end

T["setup() enables the session file, restores it, and writes through"] = function()
	-- Exercise the real wiring rather than the module in isolation: a disabled
	-- or mis-guarded setup is exactly the failure mode that loses a change set.
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local fd = assert(io.open(session_file, "w"))
	fd:write(vim.json.encode({
		version = 1,
		current_change_id = "change-001",
		changes = {
			{
				id = "change-001",
				title = "From disk",
				files = { { path = path, status = "modified", base = O, hunks = HUNKS } },
			},
		},
		triage = { [path] = { hunk_status = { h1 = "accepted" } } },
	}))
	fd:close()

	child.lua([[require("codeforge.state").reset()]])
	-- Restart the child with the real setup() wiring pointed at this file: a
	-- disabled or mis-guarded setup is exactly the failure that loses a change
	-- set, and setup() may only run once per process (dap-ui registers once).
	child.restart({
		"--cmd",
		("lua vim.env.CODEFORGE_TEST_SESSION = %q"):format(session_file),
		"-u",
		"tests/init.lua",
	})

	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").hunk_status(%s, "h1")]], vim.inspect(path))),
		"accepted"
	)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.session").enabled()]]), true)

	-- Write-through is live: a notify after setup must reach the same file.
	local before = io.open(session_file, "r"):read("*a")
	child.lua([[
		local state = require("codeforge.state")
		state.changes[1].files[1].failures = { { reason = "changed", at = 1 } }
		state.notify_change()
	]])
	local after = io.open(session_file, "r"):read("*a")
	MiniTest.expect.equality(after ~= before, true)
	MiniTest.expect.equality(after:find("changed", 1, true) ~= nil, true)
end

return T
