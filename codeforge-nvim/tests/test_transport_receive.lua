do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

---Build a valid one-file modified change-set; `mut` may mutate it.
local function valid(mut)
	local cs = {
		id = "agent-1",
		title = "Agent change",
		files = {
			{
				path = "src/target.lua",
				status = "modified",
				base = { "local a = 1", "local b = 2", "local c = 3" },
				hunks = {
					{
						id = "h1",
						old_start = 2,
						old_lines = 1,
						new_start = 2,
						new_lines = 1,
						lines = { "-local b = 2", "+local b = 20" },
					},
				},
			},
		},
	}
	if mut then
		mut(cs)
	end
	return cs
end

---Run transport.receive(cs) in the child; returns true/false.
---Captures the error string (nil on success) in _G.__last_err.
local function recv(cs)
	return child.lua(string.format(
		[[
                local ok, err = require("codeforge.transport").receive(%s)
                _G.__last_err = ok and vim.NIL or err
                return ok == true
        ]],
		vim.inspect(cs)
	))
end

local function last_err()
	return child.lua_get([[_G.__last_err]])
end

local function state_expr(expr)
	return child.lua_get(string.format([[require("codeforge.state")%s]], expr))
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

-- ── happy paths ────────────────────────────────────────────────────────────

T["valid modified change is ingested intact"] = function()
	MiniTest.expect.equality(recv(valid()), true, { fail_reason = "receive should succeed" })
	MiniTest.expect.equality(state_expr(".get_changes()[1].id"), "agent-1")
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "Agent change")
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].base[2]"), "local b = 2")
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].hunks[1].id"), "h1")
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].hunks[1].lines[2]"), "+local b = 20")
	MiniTest.expect.equality(state_expr(".get_changes()[1].timestamp ~= nil"), true)
end

T["added file ingests without a base"] = function()
	local cs = valid(function(c)
		c.files[1].status = "added"
		c.files[1].base = nil
		c.files[1].hunks = {
			{ id = "h-add", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+hello" } },
		}
	end)
	MiniTest.expect.equality(recv(cs), true)
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].base"), vim.NIL, {
		fail_reason = "added file must not gain a base",
	})
end

T["deleted file ingests with base and all-minus hunk"] = function()
	local cs = valid(function(c)
		c.files[1].status = "deleted"
		c.files[1].hunks = {
			{
				id = "h-del",
				old_start = 1,
				old_lines = 3,
				new_start = 1,
				new_lines = 0,
				lines = { "-local a = 1", "-local b = 2", "-local c = 3" },
			},
		}
	end)
	MiniTest.expect.equality(recv(cs), true)
end

T["title defaults to the change id when omitted"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.title = nil
		end)),
		true
	)
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "agent-1")
end

T["ingested state is deep-copied from the caller's table"] = function()
	child.lua([[
                local t = {
                        id = "mut-1", title = "original",
                        files = { { path = "p.lua", status = "added",
                                hunks = { { id = "h", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+hi" } } } } },
                }
                require("codeforge.transport").receive(t)
                t.title = "CHANGED"
                t.files[1].hunks[1].lines[1] = "+BYE"
        ]])
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "original", {
		fail_reason = "later mutation of the caller's table must not leak into state",
	})
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].hunks[1].lines[1]"), "+hi")
end

T["machinery-owned fields are stripped on ingest"] = function()
	local cs = valid(function(c)
		c.status = "accepted"
		c.files[1].decision = "rejected"
		c.files[1].hunks[1].status = "accepted"
	end)
	MiniTest.expect.equality(recv(cs), true)
	MiniTest.expect.equality(state_expr(".get_changes()[1].status"), vim.NIL)
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].decision"), vim.NIL)
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].hunks[1].status"), "modified", {
		fail_reason = "hunk status is derived from its lines, never taken from the sender",
	})
end

T["relative file paths resolve against the editor cwd"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	MiniTest.expect.equality(
		state_expr(".get_changes()[1].files[1].path"),
		child.fn.fnamemodify("src/target.lua", ":p"),
		{ fail_reason = "relative paths must resolve against the editor cwd" }
	)
end

T["duplicate file paths after resolution are rejected"] = function()
	local cs = valid(function(c)
		c.files[2] = vim.deepcopy(c.files[1])
		c.files[2].path = "./src/target.lua"
	end)
	MiniTest.expect.equality(recv(cs), false)
	MiniTest.expect.equality(last_err():find("duplicate", 1, true) ~= nil, true)
end

T["re-receiving the same id replaces the pending change"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.title = "Agent change v2"
		end)),
		true
	)
	MiniTest.expect.equality(#state_expr(".get_changes()"), 1, { fail_reason = "same id must replace, not duplicate" })
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "Agent change v2")
end

-- ── selection + refresh ────────────────────────────────────────────────────

T["first received change becomes the current selection"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	MiniTest.expect.equality(state_expr(".current_change_id"), "agent-1")
	MiniTest.expect.equality(state_expr(".current_change_index"), 1)
end

T["receiving does not steal an existing selection but still refreshes"] = function()
	child.lua([[
                local state = require("codeforge.state")
                table.insert(state.changes, {
                        id = "existing", title = "Existing",
                        files = { { path = "x.lua", status = "modified", hunks = {} } },
                })
                state.current_change_id, state.current_change_index = "existing", 1
                state.set_on_change(function() _G.__refresh = (_G.__refresh or 0) + 1 end)
        ]])
	MiniTest.expect.equality(recv(valid()), true)
	MiniTest.expect.equality(state_expr(".current_change_id"), "existing", {
		fail_reason = "must not steal the user's selection",
	})
	MiniTest.expect.equality(child.lua_get([[_G.__refresh ~= nil and _G.__refresh >= 1]]), true, {
		fail_reason = "sidebar must be refreshed after ingest",
	})
end

-- ── duplicate-id guards ────────────────────────────────────────────────────

T["re-receiving an id whose file is under review is refused"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	child.lua([[require("codeforge.state").reviews[vim.fn.fnamemodify("src/target.lua", ":p")] = { hunk_status = {} }]])
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.title = "v2"
		end)),
		false
	)
	MiniTest.expect.equality(last_err():find("under review", 1, true) ~= nil, true)
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "Agent change", {
		fail_reason = "the existing change must be untouched",
	})
end

T["re-receiving a completed id is refused"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	child.lua([[
                local state = require("codeforge.state")
                state.completed["agent-1"] = {}
                table.remove(state.changes)
        ]])
	MiniTest.expect.equality(recv(valid()), false)
	MiniTest.expect.equality(last_err():find("completed", 1, true) ~= nil, true)
end

-- ── shape validation ───────────────────────────────────────────────────────

T["missing id is rejected and ingests nothing"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.id = nil
		end)),
		false
	)
	MiniTest.expect.equality(#state_expr(".get_changes()"), 0)
	MiniTest.expect.equality(#(last_err() or "") > 0, true)
end

T["empty-string id is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.id = ""
		end)),
		false
	)
end

T["empty files list is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files = {}
		end)),
		false
	)
end

T["files as a dict rather than a list is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files = { path = "src/target.lua" }
		end)),
		false
	)
end

T["unknown file status is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].status = "renamed"
		end)),
		false
	)
end

T["modified file without base is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].base = nil
		end)),
		false
	)
end

T["added file carrying a base is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].status = "added"
			c.files[1].hunks = {
				{ id = "h", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+x" } },
			}
		end)),
		false
	)
end

T["modified file without hunks is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks = {}
		end)),
		false
	)
end

T["non-numeric hunk offsets are rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[1].old_start = "2"
		end)),
		false
	)
end

T["hunk offset below 1 is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[1].old_start = 0
		end)),
		false
	)
end

T["negative hunk length is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[1].old_lines = -1
		end)),
		false
	)
end

T["hunk range past the end of base is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[1].old_start = 3
			c.files[1].hunks[1].old_lines = 2 -- 3+2-1 = 4 > #base = 3
		end)),
		false
	)
end

T["context lines (neither + nor -) are rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[1].lines = { " local b = 2", "+local b = 20" }
		end)),
		false,
		{ fail_reason = "context lines are not supported by the wire format yet" }
	)
end

T["line counts disagreeing with hunk lengths are rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[1].lines = { "-local b = 2", "+local b = 20", "+local b = 200" }
		end)),
		false,
		{ fail_reason = "two '+' lines with new_lines = 1 must be rejected" }
	)
end

T["duplicate hunk ids within one file are rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[2] = vim.deepcopy(c.files[1].hunks[1])
		end)),
		false
	)
end

T["duplicate hunk ids across files are rejected"] = function()
	local cs = valid(function(c)
		local clone = vim.deepcopy(c.files[1])
		clone.path = "src/other.lua"
		c.files[2] = clone
	end)
	MiniTest.expect.equality(recv(cs), false)
end

T["base as a dict rather than a line list is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].base = { content = "local a = 1" }
		end)),
		false
	)
end

return T
