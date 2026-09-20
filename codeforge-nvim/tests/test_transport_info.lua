do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

local project_dir, original_cwd

---Send one wire frame and return the decoded reply.
local function request(value)
	return child.lua_get(string.format([[require("codeforge.protocol").handle(%q)]], vim.json.encode(value)))
end

---A valid one-file modified proposal; `mut` may alter it.
local function proposal(mut)
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

local function publish(cs)
	return request({ op = "publish", proposal = cs or proposal() })
end

---The sidebar buffer, found by filetype (never wins[#wins]: dap-ui leaves an
---empty mirror window).
local function sidebar_buf()
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_get_option_value("filetype", { buf = b }) == "codeforge" then
			return b
		end
	end
	return nil
end

---Poll up to ~1s for a sidebar line containing `substr`.
local function await_line(substr)
	for _ = 1, 40 do
		local sb = sidebar_buf()
		if sb then
			for _, l in ipairs(child.api.nvim_buf_get_lines(sb, 0, -1, false)) do
				if l:find(substr, 1, true) then
					return l
				end
			end
		end
		child.lua([[vim.wait(25)]])
	end
	return nil
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			original_cwd = child.fn.getcwd()
			project_dir = F.tmp_path("_project")
			child.fn.mkdir(project_dir .. "/src", "p")
			child.api.nvim_set_current_dir(project_dir)
			child.fn.writefile(proposal().files[1].base, project_dir .. "/src/target.lua")
			child.lua([[
				local state = require("codeforge.state")
				state.reset()
				state.log_file = nil
			]])
		end,
		post_case = function()
			child.api.nvim_set_current_dir(original_cwd)
			child.fn.delete(project_dir, "rf")
			F.cleanup()
		end,
		post_once = child.stop,
	},
})

-- ── info: the client must be able to learn where to publish ────────────────

T["info reports the cwd that relative publish paths resolve against"] = function()
	local reply = request({ op = "info" })
	MiniTest.expect.equality(reply.ok, true)
	-- Resolved, not the raw cwd: a symlinked cwd would otherwise not match the
	-- containment check that publish performs.
	local want = child.lua_get([[vim.fs.normalize(vim.uv.fs_realpath(vim.fn.getcwd()))]])
	MiniTest.expect.equality(reply.result.cwd, want)
	MiniTest.expect.equality(reply.result.cwd, child.fn.fnamemodify(project_dir, ":p"):gsub("/$", ""))
end

T["info reports the socket address so a client can connect without guessing"] = function()
	child.lua([[require("codeforge.transport").setup_socket("/tmp/cf-info-probe.sock")]])
	local reply = request({ op = "info" })
	MiniTest.expect.equality(reply.result.socket, "/tmp/cf-info-probe.sock")
	child.lua([[require("codeforge.transport").setup_socket(false)]])
	-- With no socket running, the default path is still reported rather than
	-- omitted, so a client can see what it would use.
	local idle = request({ op = "info" })
	MiniTest.expect.equality(type(idle.result.socket), "string")
	MiniTest.expect.equality(#idle.result.socket > 0, true)
end

T["info reports how many changes are tracked, without touching them"] = function()
	MiniTest.expect.equality(publish().ok, true)
	child.lua([[require("codeforge.state").set_on_change(function() error("info must not refresh") end)]])
	child.lua([[_G.__changes_before = vim.deepcopy(require("codeforge.state").changes)]])
	local reply = request({ op = "info" })
	MiniTest.expect.equality(reply.result.changes, 1)
	MiniTest.expect.equality(
		child.lua_get([[vim.deep_equal(_G.__changes_before, require("codeforge.state").changes)]]),
		true
	)
end

T["info is read-only: no buffers opened and no log entries written"] = function()
	MiniTest.expect.equality(publish().ok, true)
	child.lua([[
		_G.__bufs = vim.api.nvim_list_bufs()
		_G.__log = #require("codeforge.state").log
	]])
	request({ op = "info" })
	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(_G.__bufs, vim.api.nvim_list_bufs())]]), true)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), child.lua_get([[_G.__log]]))
end

T["info takes no extra fields and is the only read-only op"] = function()
	local reply = request({ op = "info", id = "x" })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_request")
end

T["only the four known ops exist, and none is a file-access escape hatch"] = function()
	for _, op in ipairs({ "cwd", "read", "exec", "retract", "Info", "info ", "list " }) do
		local reply = request({ op = op })
		MiniTest.expect.equality(reply.ok, false, { fail_reason = "op " .. op .. " must be refused" })
		MiniTest.expect.equality(reply.error.code, "unknown_operation")
	end
end

-- ── hunk descriptions travel with the proposal ─────────────────────────────

T["a hunk description is accepted and stored on the hunk"] = function()
	local reply = publish(proposal(function(cs)
		cs.files[1].hunks[1].description = "Raise b to 20"
	end))
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(
		child.lua_get([=[require("codeforge.state").changes[1].files[1].hunks[1].description]=]),
		"Raise b to 20"
	)
end

T["a description is display metadata only: it never affects identity or triage"] = function()
	local reply = publish(proposal(function(cs)
		cs.files[1].hunks[1].description = "Raise b to 20"
	end))
	local hunk = child.lua_get([=[require("codeforge.state").changes[1].files[1].hunks[1]]=])
	MiniTest.expect.equality(hunk.id, reply.result.files[1].hunks[1].id)
	-- Identity stays Neovim-assigned and is not derived from the description.
	MiniTest.expect.equality(hunk.id:find("cf-", 1, true), 1)
	MiniTest.expect.equality(hunk.status, "modified")
end

T["a hunk without a description is unchanged, not given a placeholder"] = function()
	local reply = publish()
	MiniTest.expect.equality(reply.ok, true)
	-- Asserted in the child so a genuinely absent key cannot be confused with a
	-- null-valued one by the RPC boundary.
	MiniTest.expect.equality(
		child.lua_get([=[require("codeforge.state").changes[1].files[1].hunks[1].description == nil]=]),
		true
	)
end

T["a malformed description is refused rather than stored"] = function()
	for _, bad in ipairs({ 42, true, { "x" }, "" }) do
		child.lua([[require("codeforge.state").reset()]])
		local reply = publish(proposal(function(cs)
			cs.files[1].hunks[1].description = bad
		end))
		MiniTest.expect.equality(
			reply.ok,
			false,
			{ fail_reason = "description " .. vim.inspect(bad) .. " must be refused" }
		)
		MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	end
end

T["an oversized or control-character-bearing description is refused"] = function()
	local cases = {
		string.rep("x", 4097),
		"has\nnewline",
		"has\ttab",
		"has\0nul",
	}
	for _, bad in ipairs(cases) do
		child.lua([[require("codeforge.state").reset()]])
		local reply = publish(proposal(function(cs)
			cs.files[1].hunks[1].description = bad
		end))
		MiniTest.expect.equality(reply.ok, false, {
			fail_reason = ("description %q must be refused"):format(bad:sub(1, 20)),
		})
		MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	end
end

T["a description is not silently treated as an id or a diff field"] = function()
	-- `id` is machinery-owned at both layers: the protocol allowlist refuses the
	-- unknown field, and transport.validate refuses it even off-wire.
	local wire = publish(proposal(function(cs)
		cs.files[1].hunks[1].description = "fine"
		cs.files[1].hunks[1].id = "agent-chosen"
	end))
	MiniTest.expect.equality(wire.ok, false)
	MiniTest.expect.equality(wire.error.message:find("unsupported field", 1, true) ~= nil, true)

	local off_wire = child.lua_get(string.format(
		[[(function()
			local cs = %s
			cs.files[1].hunks[1].description = "fine"
			cs.files[1].hunks[1].id = "agent-chosen"
			return require("codeforge.transport").validate(cs)
		end)()]],
		vim.inspect(proposal())
	))
	MiniTest.expect.equality(off_wire:find("id is assigned by Neovim", 1, true) ~= nil, true)
end

T["the receipt never echoes descriptions back"] = function()
	local reply = publish(proposal(function(cs)
		cs.files[1].hunks[1].description = "Raise b to 20"
	end))
	MiniTest.expect.equality(
		vim.deep_equal(reply.result, {
			id = reply.result.id,
			files = { { path = reply.result.files[1].path, hunks = { { id = reply.result.files[1].hunks[1].id } } } },
		}),
		true
	)
end

T["a wire-supplied description is what the sidebar renders, not the id"] = function()
	MiniTest.expect.equality(
		publish(proposal(function(cs)
			cs.files[1].hunks[1].description = "Raise b to 20"
		end)).ok,
		true
	)
	child.cmd("CodeForge")
	-- Expand the file row (line 3) to reveal its hunks.
	child.type_keys("3gg")
	child.type_keys("o")

	local row = await_line("Raise b to 20")
	MiniTest.expect.equality(row ~= nil, true, { fail_reason = "description should be rendered" })
	-- The Neovim-assigned id must not leak into the row once a description is
	-- supplied; it stays a handle, not display text.
	local hunk_id = child.lua_get([=[require("codeforge.state").changes[1].files[1].hunks[1].id]=])
	MiniTest.expect.equality(row:find(hunk_id, 1, true) == nil, true, {
		fail_reason = "hunk id should not be shown when a description exists; got " .. row,
	})
end

T["a description survives the session snapshot, since it is display metadata"] = function()
	local session_file = vim.fn.tempname() .. ".json"
	MiniTest.expect.equality(
		publish(proposal(function(cs)
			cs.files[1].hunks[1].description = "Raise b to 20"
		end)).ok,
		true
	)
	child.lua(string.format(
		[[
		require("codeforge.session").configure(%q)
		require("codeforge.session").save()
		require("codeforge.state").reset()
		require("codeforge.session").load()
	]],
		session_file
	))
	MiniTest.expect.equality(
		child.lua_get([=[require("codeforge.state").changes[1].files[1].hunks[1].description]=]),
		"Raise b to 20"
	)
	os.remove(session_file)
end

return T
