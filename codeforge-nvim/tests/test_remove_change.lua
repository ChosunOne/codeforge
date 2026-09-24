do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

---Seed N changes with distinct ids and select index `sel` (1-based).
---Point the log file at a temp path for this case (auto-cleaned).
local function use_temp_logfile()
	local p = F.tmp_path("_log.json")
	child.lua(string.format([[require("codeforge.state").log_file = %s]], vim.inspect(p)))
	return p
end

local function seed(ids, sel)
	child.lua(
		string.format(
			[[
        local state = require("codeforge.state")
        state.reset()
        state.changes = {}
        for _, id in ipairs(%s) do
                table.insert(state.changes, {
                        id = id,
                        title = "T " .. id,
                        files = { { path = id .. ".lua", status = "modified", hunks = {} } },
                })
        end
        %s
]],
			vim.inspect(ids),
			sel and string.format("state.current_change_index = %d; state.current_change_id = %q", sel, ids[sel]) or ""
		)
	)
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

T["removing the only change empties the change list and selection"] = function()
	seed({ "a" }, 1)
	child.lua([[require("codeforge.state").remove_change("a")]])

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 0, {
		fail_reason = "change list should be empty",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change()]]), vim.NIL, {
		fail_reason = "no current change should remain",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").current_change_index]]), vim.NIL, {
		fail_reason = "index should be nil",
	})
end

T["removing the current (middle) change selects the change shifted into its slot"] = function()
	seed({ "a", "b", "c" }, 2)
	child.lua([[require("codeforge.state").remove_change("b")]])

	local changes = child.lua_get([[require("codeforge.state").get_changes()]])
	MiniTest.expect.equality(#changes, 2, { fail_reason = "two changes should remain" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change().id]]), "c", {
		fail_reason = "selection should land on the change that shifted into the slot",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").current_change_id]]), "c", {
		fail_reason = "current_change_id should track the selected change",
	})
end

T["removing an earlier change keeps the currently selected change selected"] = function()
	seed({ "a", "b", "c" }, 2)
	child.lua([[require("codeforge.state").remove_change("a")]])

	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change().id]]), "b", {
		fail_reason = "b should stay selected after removing a change before it",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").current_change_index]]), 1, {
		fail_reason = "index should shift down with the removal",
	})
end

T["removing a later change leaves the selection untouched"] = function()
	seed({ "a", "b", "c" }, 2)
	child.lua([[require("codeforge.state").remove_change("c")]])

	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change().id]]), "b", {
		fail_reason = "b should stay selected",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").current_change_index]]), 2, {
		fail_reason = "index should not move",
	})
end

T["removing an unknown id is a no-op"] = function()
	seed({ "a", "b" }, 1)
	local ok = child.lua_get([[require("codeforge.state").remove_change("nope")]])

	MiniTest.expect.equality(ok, false, { fail_reason = "should report not-removed" })
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 2, {
		fail_reason = "no change should disappear",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_current_change().id]]), "a", {
		fail_reason = "selection should be untouched",
	})
end

T["removing a change cleans its expansion state and notifies"] = function()
	seed({ "a", "b" }, 1)
	child.lua([[
                local state = require("codeforge.state")
                state.expanded_files["a"] = { ["a.lua"] = true }
                state.set_on_change(function() state._notified = (state._notified or 0) + 1 end)
                state._notified = 0
        ]])
	child.lua([[require("codeforge.state").remove_change("a")]])

	MiniTest.expect.equality(child.lua_get([=[require("codeforge.state").expanded_files["a"]]=]), vim.NIL, {
		fail_reason = "expansion state for the removed change should be cleaned",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state")._notified]]), 1, {
		fail_reason = "removal should notify the render loop",
	})
end

T["remove_change appends a decision-log entry with id, timestamp, and derived status"] = function()
	seed({ "a" }, 1)
	child.lua([[require("codeforge.state").remove_change("a")]])

	local log = child.lua_get([[require("codeforge.state").log]])
	MiniTest.expect.equality(#log, 1, { fail_reason = "exactly one entry should be logged, got " .. vim.inspect(log) })
	local e = log[1]
	MiniTest.expect.equality(e.id, "a", { fail_reason = "entry id should be the removed change's id" })
	MiniTest.expect.equality(e.title, "T a", { fail_reason = "entry should carry the title" })
	MiniTest.expect.equality(type(e.timestamp), "number", { fail_reason = "timestamp should be a number" })
	MiniTest.expect.equality(e.status, "accepted", {
		fail_reason = "a change with no hunks and no decisions derives as accepted, got " .. tostring(e.status),
	})
end

T["log entry captures per-hunk outcomes, modified flag, and atomic decisions"] = function()
	child.lua([[
                local state = require("codeforge.state")
                state.reset()
                state.changes = {
                        {
                                id = "mix",
                                title = "Mixed",
                                files = {
                                        {
                                                path = "src/m.lua",
                                                status = "modified",
                                                hunks = {
                                                        { id = "h1", description = "h1", status = "modified", new_start = 1 },
                                                        { id = "h2", description = "h2", status = "modified", new_start = 2 },
                                                },
                                        },
                                        { path = "src/new.lua", status = "added", hunks = {} },
                                },
                        },
                }
                state.current_change_index = 1
                state.current_change_id = "mix"
                -- fake reviews (derive_status reads hunk_status/user_modified off these)
                state.set_review("src/m.lua", {
                        hunk_status = { h1 = "accepted", h2 = "rejected" },
                        user_modified = true,
                })
                state.changes[1].files[2].decision = "accepted"
        ]])
	child.lua([[require("codeforge.state").remove_change("mix")]])

	local e = child.lua_get([=[require("codeforge.state").log[1]]=])
	MiniTest.expect.equality(e.status, "modified", {
		fail_reason = "mixed accept/reject + user edits should derive as modified, got " .. tostring(e.status),
	})
	local mf, nf = e.files[1], e.files[2]
	MiniTest.expect.equality(mf.hunks[1].status, "accepted", { fail_reason = "h1 outcome should be accepted" })
	MiniTest.expect.equality(mf.hunks[2].status, "rejected", { fail_reason = "h2 outcome should be rejected" })
	MiniTest.expect.equality(mf.modified, true, { fail_reason = "user_modified should surface as file.modified" })
	MiniTest.expect.equality(nf.decision, "accepted", { fail_reason = "atomic file decision should be captured" })
end

T["removing an unknown id logs nothing"] = function()
	seed({ "a" }, 1)
	child.lua([[require("codeforge.state").remove_change("nope")]])

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").log]]), 0, {
		fail_reason = "no entry should be logged for an unknown id",
	})
end

T["state.reset clears the in-memory log"] = function()
	seed({ "a" }, 1)
	child.lua([[require("codeforge.state").remove_change("a")]])
	child.lua([[require("codeforge.state").reset()]])

	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").log]]), 0, {
		fail_reason = "reset should empty the log",
	})
end

T["removal persists the entry to log_file as one JSONL line"] = function()
	seed({ "a" }, 1)
	local p = use_temp_logfile()
	child.lua([[require("codeforge.state").remove_change("a")]])

	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(#lines, 1, { fail_reason = "exactly one entry line" })
	local ok, entry = pcall(vim.json.decode, lines[1])
	MiniTest.expect.equality(ok, true, { fail_reason = "line should be valid JSON, got " .. lines[1] })
	MiniTest.expect.equality(entry.id, "a", { fail_reason = "entry id should be in the line" })
end

T["persistence appends to a pre-existing log file, preserving older entries"] = function()
	seed({ "a", "b" }, 1)
	local p = use_temp_logfile()
	local old = vim.json.encode({ id = "older", title = "Old", timestamp = 1, status = "rejected", files = {} })
	vim.fn.writefile({ old }, p)

	child.lua([[require("codeforge.state").remove_change("a")]])
	child.lua([[require("codeforge.state").remove_change("b")]])

	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(#lines, 3, { fail_reason = "old entry + two new entries" })
	MiniTest.expect.equality(vim.json.decode(lines[1]).id, "older", { fail_reason = "pre-existing entry must survive" })
	MiniTest.expect.equality(vim.json.decode(lines[2]).id, "a", { fail_reason = "new entries append in order" })
	MiniTest.expect.equality(vim.json.decode(lines[3]).id, "b", { fail_reason = "new entries append in order" })
end

T["a legacy JSON-array log is migrated to JSONL without losing entries"] = function()
	seed({ "a" }, 1)
	local p = use_temp_logfile()
	local legacy = vim.json.encode({
		{ id = "legacy-1", title = "L1", timestamp = 1, status = "accepted", files = {} },
		{ id = "legacy-2", title = "L2", timestamp = 2, status = "rejected", files = {} },
	})
	vim.fn.writefile({ legacy }, p)

	-- Reading migrates the file in place, keeping order and entries intact.
	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 2)
	MiniTest.expect.equality(entries[1].id, "legacy-1")

	child.lua([[require("codeforge.state").remove_change("a")]])
	local lines = vim.fn.readfile(p)
	MiniTest.expect.equality(#lines, 3, { fail_reason = "migrated entries must survive the next append" })
	MiniTest.expect.equality(vim.json.decode(lines[1]).id, "legacy-1")
	MiniTest.expect.equality(vim.json.decode(lines[2]).id, "legacy-2")
	MiniTest.expect.equality(vim.json.decode(lines[3]).id, "a")
end

T["a corrupt log line does not break removal; the entry is still appended"] = function()
	seed({ "a" }, 1)
	local p = use_temp_logfile()
	vim.fn.writefile({ "this is not json {{{" }, p)

	local ok = child.lua_get([[require("codeforge.state").remove_change("a")]])
	MiniTest.expect.equality(ok, true, { fail_reason = "removal must succeed despite a corrupt log line" })

	local entries = child.lua_get([[require("codeforge.state").read_log_file()]])
	MiniTest.expect.equality(#entries, 1, { fail_reason = "the corrupt line must be skipped" })
	MiniTest.expect.equality(entries[1].id, "a")
end

T["log_file in a nonexistent directory is created (mkdir -p)"] = function()
	seed({ "a" }, 1)
	local dir = F.tmp_path("_logdir")
	local p = dir .. "/nested/log.json"
	child.lua(string.format([[require("codeforge.state").log_file = %s]], vim.inspect(p)))

	child.lua([[require("codeforge.state").remove_change("a")]])

	MiniTest.expect.equality(vim.fn.filereadable(p), 1, { fail_reason = "log file should exist after mkdir -p" })
end

T["nil log_file disables persistence without breaking removal"] = function()
	seed({ "a" }, 1)
	child.lua([[require("codeforge.state").log_file = nil]])

	local ok = child.lua_get([[require("codeforge.state").remove_change("a")]])
	MiniTest.expect.equality(ok, true, { fail_reason = "removal must succeed with persistence off" })
	MiniTest.expect.equality(#child.lua_get([=[require("codeforge.state").log]=]), 1, {
		fail_reason = "in-memory log still records the entry",
	})
end

return T
