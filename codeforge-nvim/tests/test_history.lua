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

local function undo_stack()
	return child.lua_get([[require("codeforge.history").undo_stack]])
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

T["accepting a hunk records a hunk action with before/after status"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))

	local stack = undo_stack()
	MiniTest.expect.equality(#stack, 1, { fail_reason = "one transaction expected, got " .. vim.inspect(stack) })
	local rec = stack[1].records[1]
	MiniTest.expect.equality(rec.kind, "hunk", { fail_reason = "record kind" })
	MiniTest.expect.equality(rec.path, path, { fail_reason = "record path" })
	MiniTest.expect.equality(rec.hunk_id, "h1", { fail_reason = "record hunk id" })
	MiniTest.expect.equality(rec.before.status == nil, true, { fail_reason = "hunk was pending before" })
	MiniTest.expect.equality(rec.after.status, "accepted", { fail_reason = "hunk accepted after" })
end

T["rejecting a hunk records the region content swap"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })

	open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):reject_hunk(3)]], vim.inspect(path)))

	local rec = undo_stack()[1].records[1]
	MiniTest.expect.equality(rec.after.status, "rejected", { fail_reason = "rejected after" })
	MiniTest.expect.equality(rec.before.region, { "D" }, {
		fail_reason = "before region should be the proposal content, got " .. vim.inspect(rec.before.region),
	})
	MiniTest.expect.equality(rec.after.region, { "d" }, {
		fail_reason = "after region should be the restored U content, got " .. vim.inspect(rec.after.region),
	})
end

T["a sweep records one record per swept hunk"] = function()
	local O = { "a", "b", "c", "d", "e" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") })
	open_review(path)

	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_pending()]], vim.inspect(path)))

	local stack = undo_stack()
	MiniTest.expect.equality(#stack, 2, {
		fail_reason = "two implicit transactions (grouping comes later), got " .. vim.inspect(#stack),
	})
	MiniTest.expect.equality(stack[1].records[1].hunk_id, "h1", { fail_reason = "first record h1" })
	MiniTest.expect.equality(stack[2].records[1].hunk_id, "h2", { fail_reason = "second record h2" })
end

T["an atomic decision flip records a decision action"] = function()
	local added = F.tmp_path()
	child.fn.writefile({ "new" }, added)
	local O = { "a1", "a2" }
	local pa = F.tmp_path()
	child.fn.writefile(O, pa)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "T",
                        files = {
                                { path = %s, status = "added", hunks = {} },
                        },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		vim.inspect(added)
	))

	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(added)))

	local rec = undo_stack()[1].records[1]
	MiniTest.expect.equality(rec.kind, "decision", { fail_reason = "record kind" })
	MiniTest.expect.equality(rec.path, added, { fail_reason = "record path" })
	MiniTest.expect.equality(rec.before.decision == nil, true, { fail_reason = "undecided before" })
	MiniTest.expect.equality(rec.after.decision, "accepted", { fail_reason = "accepted after flip" })
end

T["expansion toggles are not recorded"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })
	open_review(path)

	-- expansion state change only
	child.lua([[require("codeforge.state").toggle_file("x")]])
	-- modified-file toggle is expansion, not a decision
	child.lua(string.format([[require("codeforge.sidebar.actions").toggle_file(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(#undo_stack(), 0, {
		fail_reason = "no triage action happened; history must stay empty, got " .. vim.inspect(undo_stack()),
	})
end

T["history resets with state"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	F.seed_change(path, O, { F.replace_hunk("h1", 2, "b", "B") })
	open_review(path)
	child.lua(string.format([[require("codeforge.state").get_review(%s):accept_hunk(1)]], vim.inspect(path)))
	MiniTest.expect.equality(#undo_stack(), 1, { fail_reason = "precondition: one record" })

	child.lua([[require("codeforge.state").reset()]])

	MiniTest.expect.equality(#undo_stack(), 0, { fail_reason = "state.reset clears history" })
end

return T
