do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)
local project_dir, original_cwd

---Build a valid one-file modified change-set; `mut` may mutate it.
local function valid(mut)
	local cs = {
		title = "Agent change",
		files = {
			{
				path = "src/target.lua",
				status = "modified",
				base = { "local a = 1", "local b = 2", "local c = 3" },
				hunks = {
					{
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
                local ok, payload = require("codeforge.transport").receive(%s)
                _G.__last_err = ok and vim.NIL or payload
                _G.__last_ack = ok and payload or vim.NIL
                return ok == true
        ]],
		vim.inspect(cs)
	))
end

local function last_err()
	return child.lua_get([[_G.__last_err]])
end

local function last_ack()
	return child.lua_get([[_G.__last_ack]])
end

local function state_expr(expr)
	return child.lua_get(string.format([[require("codeforge.state")%s]], expr))
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			original_cwd = child.fn.getcwd()
			project_dir = F.tmp_path("_project")
			child.fn.mkdir(project_dir .. "/src", "p")
			child.api.nvim_set_current_dir(project_dir)
			for _, name in ipairs({ "target.lua", "other.lua" }) do
				child.fn.writefile(valid().files[1].base, project_dir .. "/src/" .. name)
			end
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_case = function()
			child.api.nvim_set_current_dir(original_cwd)
			child.fn.delete(project_dir, "rf")
			F.cleanup()
		end,
		post_once = child.stop,
	},
})

-- ── happy paths ────────────────────────────────────────────────────────────

T["valid modified change is ingested intact"] = function()
	MiniTest.expect.equality(recv(valid()), true, { fail_reason = "receive should succeed" })
	MiniTest.expect.equality(state_expr(".get_changes()[1].id"), last_ack().id)
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "Agent change")
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].base[2]"), "local b = 2")
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].hunks[1].id"), last_ack().files[1].hunks[1].id)
	MiniTest.expect.equality(state_expr(".get_changes()[1].files[1].hunks[1].lines[2]"), "+local b = 20")
	MiniTest.expect.equality(state_expr(".get_changes()[1].timestamp ~= nil"), true)
end

T["added file ingests without a base"] = function()
	local cs = valid(function(c)
		c.files[1].status = "added"
		c.files[1].base = nil
		c.files[1].hunks = {
			{ old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+hello" } },
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
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), last_ack().id)
end

T["ingested state is deep-copied from the caller's table"] = function()
	child.lua([[
                local t = {
                        title = "original",
                        files = { { path = "p.lua", status = "added",
                                hunks = { { old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+hi" } } } } },
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

T["re-publishing a pending file does not replace its change"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	local original = state_expr(".get_changes()[1]")
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.title = "Agent change v2"
		end)),
		false
	)
	MiniTest.expect.equality(#state_expr(".get_changes()"), 1)
	MiniTest.expect.equality(state_expr(".get_changes()[1]"), original)
	MiniTest.expect.equality(last_err():find("already tracked", 1, true) ~= nil, true)
end

T["a second change with an overlapping path is refused"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	local original_id = last_ack().id

	local cs = valid(function(c)
		c.files[1].hunks[1].lines = { "-local b = 2", "+local b = 200" }
	end)
	MiniTest.expect.equality(
		recv(cs),
		false,
		{ fail_reason = "a path already tracked by another change must be refused" }
	)
	MiniTest.expect.equality(last_err():find(original_id, 1, true) ~= nil, true, {
		fail_reason = "the error should name the owning change, got: " .. tostring(last_err()),
	})
	MiniTest.expect.equality(#state_expr(".get_changes()"), 1, {
		fail_reason = "the refused change must not be admitted",
	})
	MiniTest.expect.equality(state_expr(".get_changes()[1].id"), original_id, {
		fail_reason = "the tracked change must be untouched",
	})
end

T["an overlapping path is detected across relative/absolute aliases"] = function()
	MiniTest.expect.equality(recv(valid()), true)

	local abs = child.fn.fnamemodify("src/target.lua", ":p")
	local cs = valid(function(c)
		c.files[1].path = abs
	end)
	MiniTest.expect.equality(recv(cs), false, { fail_reason = "aliased paths must normalize to the same file" })
end

T["a second change touching unrelated files is admitted"] = function()
	MiniTest.expect.equality(recv(valid()), true)

	local cs = valid(function(c)
		c.files[1].path = "src/other.lua"
	end)
	MiniTest.expect.equality(recv(cs), true, { fail_reason = "unrelated paths must be admitted" })
	MiniTest.expect.equality(#state_expr(".get_changes()"), 2)
end

T["reviewing the selected change never returns another change's review"] = function()
	local path_a = "src/a.lua"
	local path_b = "src/b.lua"
	child.fn.writefile({ "local a = 1", "local x = 2" }, path_a)
	child.fn.writefile({ "local b = 1", "local y = 2" }, path_b)
	MiniTest.expect.equality(
		recv({
			files = {
				{
					path = path_a,
					status = "modified",
					base = { "local a = 1", "local x = 2" },
					hunks = {
						{
							old_start = 2,
							old_lines = 1,
							new_start = 2,
							new_lines = 1,
							lines = { "-local x = 2", "+local x = 20" },
						},
					},
				},
			},
		}),
		true
	)
	MiniTest.expect.equality(
		recv({
			files = {
				{
					path = path_b,
					status = "modified",
					base = { "local b = 1", "local y = 2" },
					hunks = {
						{
							old_start = 2,
							old_lines = 1,
							new_start = 2,
							new_lines = 1,
							lines = { "-local y = 2", "+local y = 20" },
						},
					},
				},
			},
		}),
		true
	)

	local abs_a = child.fn.fnamemodify(path_a, ":p")
	local abs_b = child.fn.fnamemodify(path_b, ":p")

	-- open change A's review, then select change B and open its review
	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(abs_a)))
	child.lua([[require("codeforge.state").next_change()]])
	MiniTest.expect.equality(state_expr(".current_change_id"), last_ack().id)
	child.lua(string.format([[require("codeforge.review.buffer").ensure_review(%s)]], vim.inspect(abs_b)))

	local review = child.lua_get(string.format([[require("codeforge.state").get_review(%s)]], vim.inspect(abs_b)))
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s).hunks[1].id]], vim.inspect(abs_b))),
		last_ack().files[1].hunks[1].id,
		{ fail_reason = "the review for B must carry B's hunks, got " .. vim.inspect(review) }
	)
end

-- ── selection + refresh ────────────────────────────────────────────────────

T["first received change becomes the current selection"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	MiniTest.expect.equality(state_expr(".current_change_id"), last_ack().id)
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

-- ── admission guards ──────────────────────────────────────────────────────

T["re-publishing a file under review is refused"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	child.lua([[require("codeforge.state").reviews[vim.fn.fnamemodify("src/target.lua", ":p")] = { hunk_status = {} }]])
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.title = "v2"
		end)),
		false
	)
	MiniTest.expect.equality(last_err():find("already tracked", 1, true) ~= nil, true)
	MiniTest.expect.equality(state_expr(".get_changes()[1].title"), "Agent change", {
		fail_reason = "the existing change must be untouched",
	})
end

T["publishing a previously completed file creates a fresh identity"] = function()
	MiniTest.expect.equality(recv(valid()), true)
	local old_id = last_ack().id
	child.lua([[
                local state = require("codeforge.state")
                local change = table.remove(state.changes)
                state.completed[change.id] = { change = change }
                state.current_change_id, state.current_change_index = nil, nil
        ]])
	MiniTest.expect.equality(recv(valid()), true)
	MiniTest.expect.equality(last_ack().id ~= old_id, true)
	MiniTest.expect.equality(#state_expr(".get_changes()"), 1)
end

-- ── shape validation ───────────────────────────────────────────────────────

T["caller-supplied id is rejected and ingests nothing"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.id = "chosen"
		end)),
		false
	)
	MiniTest.expect.equality(#state_expr(".get_changes()"), 0)
	MiniTest.expect.equality(last_err():find("id is assigned by Neovim", 1, true) ~= nil, true)
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
				{ old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+x" } },
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

T["duplicate hunk ranges within one file are rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].hunks[2] = vim.deepcopy(c.files[1].hunks[1])
		end)),
		false
	)
end

T["identical hunks across distinct files get distinct identities"] = function()
	local cs = valid(function(c)
		local clone = vim.deepcopy(c.files[1])
		clone.path = "src/other.lua"
		c.files[2] = clone
	end)
	MiniTest.expect.equality(recv(cs), true)
	MiniTest.expect.equality(last_ack().files[1].hunks[1].id ~= last_ack().files[2].hunks[1].id, true)
end

T["base as a dict rather than a line list is rejected"] = function()
	MiniTest.expect.equality(
		recv(valid(function(c)
			c.files[1].base = { content = "local a = 1" }
		end)),
		false
	)
end

-- Admission must be atomic, including a rejected publication whose first file
-- is valid and whose later file is malformed. Keep an unsaved target buffer so
-- a validator cannot accidentally use (or overwrite) live content as the base.
local function expect_rejected_unchanged(cs, message)
	MiniTest.expect.equality(recv(valid()), true)
	child.lua([[
		local state = require("codeforge.state")
		local buf = vim.fn.bufadd(vim.fn.fnamemodify("src/target.lua", ":p"))
		vim.fn.bufload(buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user edits" })
		_G.__snapshot = function()
			local buffers = {}
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				buffers[#buffers + 1] = {
					id = b, name = vim.api.nvim_buf_get_name(b),
					lines = vim.api.nvim_buf_get_lines(b, 0, -1, false),
					tick = vim.api.nvim_buf_get_changedtick(b), modified = vim.bo[b].modified,
				}
			end
			return vim.deepcopy({
				changes = state.changes, reviews = state.reviews, log = state.log,
				completed = state.completed, completed_order = state.completed_order,
				expanded = state.expanded_files,
				selection = { state.current_change_id, state.current_change_index },
				buffers = buffers,
			})
		end
		_G.__before = _G.__snapshot()
		_G.__original = state.changes[1]
		_G.__refresh = 0
		state.set_on_change(function() _G.__refresh = _G.__refresh + 1 end)
	]])
	MiniTest.expect.equality(recv(cs), false)
	MiniTest.expect.equality(last_err():find(message, 1, true) ~= nil, true, {
		fail_reason = "expected " .. message .. "; got: " .. tostring(last_err()),
	})
	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(_G.__before, _G.__snapshot())]]), true, {
		fail_reason = "rejected input must leave state and all buffers unchanged",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1] == _G.__original]]), true)
	MiniTest.expect.equality(child.lua_get([[_G.__refresh]]), 0)
end

for _, value in ipairs({ 42, false, { "nested" } }) do
	T["non-string base line is rejected: " .. type(value)] = function()
		local cs = valid(function(c)
			-- Outside the hunk: every base line must be validated.
			c.files[1].base[1] = value
		end)
		expect_rejected_unchanged(cs, "base line 1 must be a string")
	end
end

T["removed text must match the base exactly, including whitespace"] = function()
	local cs = valid(function(c)
		c.files[1].hunks[1].lines[1] = "-local b = 2 "
	end)
	expect_rejected_unchanged(cs, "hunk 1: removed line does not match base line 2")
end

T["a mismatch in a later file rejects the entire publication"] = function()
	local cs = valid(function(c)
		c.title = "replacement must not leak"
		c.files[2] = vim.deepcopy(c.files[1])
		c.files[2].path = "src/other.lua"
		c.files[2].hunks = {
			{
				old_start = 2,
				old_lines = 2,
				new_start = 2,
				new_lines = 1,
				lines = { "-local b = 2", "+replacement", "-wrong last line" },
			},
		}
	end)
	expect_rejected_unchanged(cs, "file 2: path src/other.lua: hunk 1: removed line does not match base line 3")
end

-- Half-open base ranges: [old_start, old_start + old_lines). Insertions
-- consume no base lines, but shared starts are ambiguous to apply_hunks.
local function range_hunk(label, start, count)
	local lines = {}
	for i = start, start + count - 1 do
		lines[#lines + 1] = "-line " .. i
	end
	lines[#lines + 1] = "+replacement " .. label
	return { old_start = start, old_lines = count, new_start = start, new_lines = 1, lines = lines }
end

local range_cases = {
	{ "partial overlap", 1, 2, 2, 2 },
	{ "nested range", 1, 3, 2, 1 },
	{ "duplicate range", 2, 1, 2, 1 },
	{ "insertion inside a removed range", 1, 3, 2, 0 },
	{ "insertion at the same start as a replacement", 2, 1, 2, 0 },
	{ "two insertions at the same position", 2, 0, 2, 0 },
}
for _, case in ipairs(range_cases) do
	T["rejects " .. case[1] .. " regardless of input order"] = function()
		for _, reverse in ipairs({ false, true }) do
			child.lua([[require("codeforge.state").reset()]])
			local cs = valid(function(c)
				c.files[1].base = { "line 1", "line 2", "line 3", "line 4" }
				local a, b = range_hunk("ha", case[2], case[3]), range_hunk("hb", case[4], case[5])
				c.files[1].hunks = reverse and { b, a } or { a, b }
			end)
			expect_rejected_unchanged(cs, "overlapping or ambiguous base ranges")
		end
	end
end

T["adjacent ranges and an EOF insertion are accepted without reordering input"] = function()
	local cs = valid(function(c)
		c.files[1].base = { "line 1", "line 2", "line 3", "line 4" }
		c.files[1].hunks = {
			range_hunk("end", 5, 0),
			range_hunk("right", 3, 2),
			range_hunk("left", 1, 2),
		}
		c.files[1].hunks[1].new_start = 3
		c.files[1].hunks[2].new_start = 2
	end)
	child.lua(string.format(
		[[
		local cs = %s
		local before = vim.deepcopy(cs)
		_G.__validation_error = require("codeforge.transport").validate(cs)
		_G.__input_unchanged = vim.deep_equal(cs, before)
	]],
		vim.inspect(cs)
	))
	MiniTest.expect.equality(child.lua_get([[_G.__validation_error]]), vim.NIL)
	MiniTest.expect.equality(child.lua_get([[_G.__input_unchanged]]), true)
	MiniTest.expect.equality(recv(cs), true)
	MiniTest.expect.equality(state_expr(".changes[1].files[1].hunks[1].old_start"), 5)
end

T["interleaved additions do not advance the removed-line base position"] = function()
	local cs = valid(function(c)
		c.files[1].hunks = {
			{
				old_start = 2,
				old_lines = 2,
				new_start = 2,
				new_lines = 2,
				lines = { "+first", "-local b = 2", "+second", "-local c = 3" },
			},
		}
	end)
	MiniTest.expect.equality(recv(cs), true)
end

return T
