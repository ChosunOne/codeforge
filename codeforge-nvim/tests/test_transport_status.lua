do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures")
F.set_child(child)

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			-- All temporary proposal files must belong to the editor's project.
			child.api.nvim_set_current_dir(child.fn.fnamemodify(child.fn.tempname(), ":h"))
			child.lua([[
				local state = require("codeforge.state")
				state.reset()
				state.log_file = nil
			]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

local function request(value)
	return child.lua_get(string.format([[require("codeforge.protocol").handle(%q)]], vim.json.encode(value)))
end

local function status(id)
	return request({ op = "status", id = id })
end

local function publish(path)
	local base = { "a", "b", "c", "d", "e" }
	if not path then
		path = F.tmp_path()
		child.fn.writefile(base, path)
	end
	local hunks = { F.replace_hunk("h1", 2, "b", "B"), F.replace_hunk("h2", 4, "d", "D") }
	for _, hunk in ipairs(hunks) do
		hunk.id, hunk.status, hunk.header = nil, nil, nil
	end
	local reply = request({
		op = "publish",
		proposal = { files = {
			{ path = path, status = "modified", base = base, hunks = hunks },
		} },
	})
	MiniTest.expect.equality(reply.ok, true)
	return reply.result, path, base
end

T["unknown identity returns not_found without touching state or opening buffers"] = function()
	local ack = publish()
	child.lua([[
		local state = require("codeforge.state")
		before_changes = vim.deepcopy(state.changes)
		before_buffers = vim.api.nvim_list_bufs()
		state.set_on_change(function() error("query must not refresh") end)
	]])
	local reply = status(ack.id .. "-missing")
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "not_found")
	MiniTest.expect.equality(
		child.lua_get([[vim.deep_equal(before_changes, require("codeforge.state").changes)]]),
		true
	)
	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(before_buffers, vim.api.nvim_list_bufs())]]), true)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
end

T["unopened proposal reports pending hunk outcomes, not diff display statuses"] = function()
	local ack, path = publish()
	MiniTest.expect.equality(status(ack.id), {
		ok = true,
		result = {
			id = ack.id,
			status = "pending",
			under_review = true,
			files = {
				{
					path = path,
					status = "modified",
					modified = false,
					hunks = {
						{ id = ack.files[1].hunks[1].id, status = "pending" },
						{ id = ack.files[1].hunks[2].id, status = "pending" },
					},
				},
			},
		},
	})
	MiniTest.expect.equality(child.lua_get([[next(require("codeforge.state").reviews) == nil]]), true)
end

T["accepted and conflicted hunks still aggregate to pending without completing the change"] = function()
	local ack, path = publish()
	child.lua(string.format(
		[[
		local state = require("codeforge.state")
		local hunks = state.changes[1].files[1].hunks
		state.reviews[%q] = { hunk_status = { [hunks[1].id] = "accepted", [hunks[2].id] = "conflicted" }, user_modified = true }
		state.set_on_change(function() error("query must not refresh") end)
	]],
		path
	))
	local reply = status(ack.id)
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.status, "pending")
	MiniTest.expect.equality(reply.result.under_review, true)
	MiniTest.expect.equality(reply.result.files[1].modified, true)
	MiniTest.expect.equality(reply.result.files[1].hunks, {
		{ id = ack.files[1].hunks[1].id, status = "accepted" },
		{ id = ack.files[1].hunks[2].id, status = "conflicted" },
	})
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
end

T["status validates its own allowlist and never accepts mutation or file-access fields"] = function()
	local ack = publish()
	for _, value in ipairs({
		{ op = "status" },
		{ op = "status", id = vim.NIL },
		{ op = "status", id = false },
		{ op = "status", id = 1 },
		{ op = "status", id = {} },
		{ op = "status", id = "" },
		{ op = "status", id = "bad\0id" },
		{ op = "status", id = string.rep("x", 257) },
		{ op = "status", id = ack.id, proposal = {} },
		{ op = "status", id = ack.id, path = "/etc/passwd" },
		{ op = "status", id = ack.id, status = "accepted" },
		{ op = "publish", id = ack.id, proposal = {} },
	}) do
		local reply = request(value)
		MiniTest.expect.equality(reply.ok, false)
		MiniTest.expect.equality(reply.error.code, "invalid_request")
	end
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
end

local function open_proposal()
	local ack, path = publish()
	child.lua(string.format([[require("codeforge.review.buffer").open(%q)]], path))
	return ack, path
end

local function triage(path, action, row)
	child.lua(string.format([[require("codeforge.state").get_review(%q):%s_hunk(%d)]], path, action, row))
end

T["mixed completion reports frozen outcomes even when another change reviews the same path"] = function()
	local ack, path = open_proposal()
	triage(path, "accept", 1)
	local partial = status(ack.id)
	MiniTest.expect.equality(partial.result.status, "pending")
	MiniTest.expect.equality(partial.result.files[1].hunks[2].status, "pending")
	triage(path, "reject", 3)
	local done = status(ack.id)
	MiniTest.expect.equality(done.ok, true)
	MiniTest.expect.equality(done.result.status, "modified")
	MiniTest.expect.equality(done.result.under_review, false)
	MiniTest.expect.equality(done.result.files[1].modified, false)
	MiniTest.expect.equality(done.result.files[1].hunks, {
		{ id = ack.files[1].hunks[1].id, status = "accepted" },
		{ id = ack.files[1].hunks[2].id, status = "rejected" },
	})
	local newer = publish(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%q)]], path))
	MiniTest.expect.equality(status(newer.id).result.status, "pending")
	MiniTest.expect.equality(status(ack.id), done)
end

T["undo beats stale completion log entries and redo reports completion again"] = function()
	local ack, path = open_proposal()
	triage(path, "reject", 1)
	triage(path, "reject", 3)
	local done = status(ack.id)
	MiniTest.expect.equality(done.ok, true)
	MiniTest.expect.equality(done.result.status, "rejected")
	MiniTest.expect.equality(done.result.under_review, false)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.sidebar.actions").undo()]]), 1)
	local revived = status(ack.id).result
	MiniTest.expect.equality(revived.status, "pending")
	MiniTest.expect.equality(revived.under_review, true)
	MiniTest.expect.equality(revived.files[1].hunks[1].status, "rejected")
	MiniTest.expect.equality(revived.files[1].hunks[2].status, "pending")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.sidebar.actions").redo()]]), 1)
	MiniTest.expect.equality(status(ack.id), done)
end

T["reopen reports a fresh pending round before opening any buffer, then the new outcome"] = function()
	local ack, path = open_proposal()
	triage(path, "accept", 1)
	triage(path, "accept", 3)
	MiniTest.expect.equality(status(ack.id).result.status, "accepted")
	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").reopen_change(%q)]], ack.id)),
		true
	)
	local reopened = status(ack.id).result
	MiniTest.expect.equality(reopened.status, "pending")
	MiniTest.expect.equality(reopened.under_review, true)
	for _, hunk in ipairs(reopened.files[1].hunks) do
		MiniTest.expect.equality(hunk.status, "pending")
	end
	MiniTest.expect.equality(child.lua_get([[next(require("codeforge.state").reviews) == nil]]), true)
	child.lua(string.format([[require("codeforge.review.buffer").open(%q)]], path))
	triage(path, "reject", 1)
	triage(path, "reject", 3)
	MiniTest.expect.equality(status(ack.id).result.status, "rejected")
	MiniTest.expect.equality(status(ack.id).result.under_review, false)
end

T["hand-edited acceptance preserves the modified flag after review teardown"] = function()
	local ack, path = open_proposal()
	child.api.nvim_win_set_cursor(0, { 2, 0 })
	child.type_keys("A-edited<Esc>")
	MiniTest.expect.equality(
		child.lua_get(string.format(
			[[
		vim.wait(1500, function()
			return require("codeforge.state").get_review(%q).user_modified
		end, 10)
	]],
			path
		)),
		true
	)
	triage(path, "accept", 1)
	triage(path, "accept", 3)
	local done = status(ack.id).result
	MiniTest.expect.equality(done.status, "modified")
	MiniTest.expect.equality(done.under_review, false)
	MiniTest.expect.equality(done.files[1].modified, true)
	for _, hunk in ipairs(done.files[1].hunks) do
		MiniTest.expect.equality(hunk.status, "accepted")
	end
	MiniTest.expect.equality(child.lua_get([[next(require("codeforge.state").reviews) == nil]]), true)
end

T["a fully triaged but still tracked change remains under review and querying never finalizes it"] = function()
	local ack, path = publish()
	child.lua(string.format(
		[[
		local state = require("codeforge.state")
		local hunks = state.changes[1].files[1].hunks
		state.reviews[%q] = {
			hunk_status = { [hunks[1].id] = "accepted", [hunks[2].id] = "accepted" },
			user_modified = true,
			preflight = function() error("query must not try completion") end,
		}
		state.set_on_change(function() error("query must not refresh") end)
	]],
		path
	))
	local reply = status(ack.id)
	MiniTest.expect.equality(reply.result.status, "modified")
	MiniTest.expect.equality(reply.result.under_review, true)
	MiniTest.expect.equality(reply.result.files[1].modified, true)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
	MiniTest.expect.equality(child.lua_get([[next(require("codeforge.state").completed) == nil]]), true)
end

T["atomic added and deleted files report decisions, never their diff type as an outcome"] = function()
	local reply = request({
		op = "publish",
		proposal = {
			files = {
				{
					path = F.tmp_path(),
					status = "added",
					hunks = {
						{ old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+new" } },
					},
				},
				{
					path = F.tmp_path(),
					status = "deleted",
					base = { "old" },
					hunks = {
						{ old_start = 1, old_lines = 1, new_start = 1, new_lines = 0, lines = { "-old" } },
					},
				},
			},
		},
	})
	MiniTest.expect.equality(reply.ok, true)
	local id = reply.result.id
	MiniTest.expect.equality(status(id).result.files[1].decision, "pending")
	MiniTest.expect.equality(status(id).result.files[2].decision, "pending")
	child.lua([[require("codeforge.state").changes[1].files[1].decision = "accepted"]])
	MiniTest.expect.equality(status(id).result.status, "pending")
	MiniTest.expect.equality(status(id).result.files[1].decision, "accepted")
	child.lua([[
		local state = require("codeforge.state")
		state.changes[1].files[2].decision = "rejected"
		assert(state.maybe_complete(state.changes[1]))
	]])
	local done = status(id).result
	MiniTest.expect.equality(done.status, "modified")
	MiniTest.expect.equality(done.under_review, false)
	MiniTest.expect.equality(done.files, {
		{ path = reply.result.files[1].path, status = "added", decision = "accepted" },
		{ path = reply.result.files[2].path, status = "deleted", decision = "rejected" },
	})
end

T["snapshots are detached from active reviews and completed log entries"] = function()
	local ack, path = open_proposal()
	triage(path, "accept", 1)
	local partial = status(ack.id)
	child.lua(string.format(
		[[
		local result = require("codeforge.state").get_change_status(%q)
		result.files[1].hunks[1].status = "rejected"
		result.files[1].path = "injected"
		result.files[2] = { path = "injected" }
	]],
		ack.id
	))
	MiniTest.expect.equality(status(ack.id), partial)
	triage(path, "reject", 3)
	local done = status(ack.id)
	child.lua(string.format(
		[[
		local state = require("codeforge.state")
		before_entry = vim.deepcopy(state.completed[%q].entry)
		before_log = vim.deepcopy(state.log)
		local result = state.get_change_status(%q)
		result.status = "accepted"
		result.files[1].hunks[1].status = "rejected"
		table.remove(result.files, 1)
	]],
		ack.id,
		ack.id
	))
	MiniTest.expect.equality(status(ack.id), done)
	MiniTest.expect.equality(
		child.lua_get(
			string.format([[vim.deep_equal(before_entry, require("codeforge.state").completed[%q].entry)]], ack.id)
		),
		true
	)
	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(before_log, require("codeforge.state").log)]]), true)
end

T["a completed change is still queryable after the session forgets it"] = function()
	local ack, path = open_proposal()
	local log_path = F.tmp_path("_log.json")
	child.lua(string.format([[require("codeforge.state").log_file = %q]], log_path))
	triage(path, "reject", 1)
	triage(path, "reject", 3)
	MiniTest.expect.equality(status(ack.id).result.status, "rejected")
	MiniTest.expect.equality(child.fn.filereadable(log_path), 1)
	child.lua([[require("codeforge.state").reset()]])
	child.lua(string.format([[require("codeforge.state").log_file = %q]], log_path))
	local after = status(ack.id)
	MiniTest.expect.equality(after.ok, true)
	MiniTest.expect.equality(after.result.status, "rejected")
	MiniTest.expect.equality(after.result.under_review, false)
	MiniTest.expect.equality(after.result.files[1].status, "modified")
	MiniTest.expect.equality(after.result.files[1].hunks[1].status, "rejected")
end

T["a persisted outcome never overrides live state or a retained completion"] = function()
	-- A stale log entry for an id that is live again (undo/reopen) must not win:
	-- live membership and retained completions are always consulted first.
	local ack, path = open_proposal()
	local log_path = F.tmp_path("_log.json")
	child.lua(string.format([[require("codeforge.state").log_file = %q]], log_path))
	triage(path, "reject", 1)
	triage(path, "reject", 3)
	MiniTest.expect.equality(status(ack.id).result.status, "rejected")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.sidebar.actions").undo()]]), 1)

	-- Stale entry says rejected; live state says pending.
	local revived = status(ack.id).result
	MiniTest.expect.equality(revived.status, "pending")
	MiniTest.expect.equality(revived.under_review, true)
end

T["an unknown id is still not_found, not a log scan for anything"] = function()
	local log_path = F.tmp_path("_log.json")
	child.lua(string.format([[require("codeforge.state").log_file = %q]], log_path))
	MiniTest.expect.equality(status("cf-never-existed").error.code, "not_found")
end

T["a corrupt or unreadable decision log yields not_found rather than an error"] = function()
	local log_path = F.tmp_path("_log.json")
	child.fn.writefile({ "{not json" }, log_path)
	child.lua(string.format([[require("codeforge.state").log_file = %q]], log_path))
	child.lua(string.format(
		[[
			local state = require("codeforge.state")
			state.reset()
			state.log_file = %q
		]],
		log_path
	))
	local reply = status("cf-corrupt-probe")
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "not_found")
end

T["an id supplied to status is still strictly validated"] = function()
	for _, bad in ipairs({ {}, true, 1, "", string.rep("x", 257) }) do
		local reply = status(bad)
		MiniTest.expect.equality(reply.ok, false, { fail_reason = vim.inspect(bad) .. " must be refused" })
		MiniTest.expect.equality(reply.error.code, "invalid_request")
	end
end

return T
