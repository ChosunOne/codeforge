do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures")
F.set_child(child)
local clients = {}
local sock

local function await(predicate, why)
	MiniTest.expect.equality(vim.wait(2000, predicate, 5), true, { fail_reason = why })
end

local function connect(path)
	local client = { pipe = vim.uv.new_pipe(false), data = "", eof = false }
	clients[#clients + 1] = client
	client.pipe:connect(path or sock, function(err)
		client.connected, client.error = true, err
		if err then
			return
		end
		client.pipe:read_start(function(read_err, data)
			client.error = read_err or client.error
			if data then
				client.data = client.data .. data
			else
				client.eof = true
			end
		end)
	end)
	await(function()
		return client.connected
	end, "client connection never completed")
	MiniTest.expect.equality(client.error, nil)
	return client
end

local function send(client, data)
	local done
	client.pipe:write(data, function(err)
		client.write_error, done = err, true
	end)
	await(function()
		return done
	end, "client write never completed")
end

local function response(client)
	await(function()
		return client.eof
	end, "server did not finish the one-request connection")
	MiniTest.expect.equality(client.data:sub(-1), "\n")
	return vim.json.decode(client.data)
end

local function proposal(path)
	return {
		title = "Wire proposal",
		files = {
			{
				path = path or "wire-target.lua",
				status = "added",
				hunks = {
					{
						old_start = 1,
						old_lines = 0,
						new_start = 1,
						new_lines = 1,
						lines = { "+return 'hello'" },
					},
				},
			},
		},
	}
end

local function request(p)
	return vim.json.encode({ op = "publish", proposal = p or proposal() }) .. "\n"
end

local function start(opts)
	opts = opts or {}
	opts.path = opts.path or sock
	child.lua(string.format([[require("codeforge.transport").setup_socket(%s)]], vim.inspect(opts)))
end

local function unchanged()
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
	MiniTest.expect.equality(child.lua_get([[vim.g.codeforge_execution_probe]]), vim.NIL)
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.lua([[require("codeforge.state").reset()]])
			sock = F.tmp_path("_api.sock")
			clients = {}
		end,
		post_case = function()
			for _, client in ipairs(clients) do
				if not client.pipe:is_closing() then
					client.pipe:close()
				end
			end
			child.lua([[require("codeforge.transport").setup_socket(false)]])
			F.cleanup()
		end,
		post_once = child.stop,
	},
})

T["dedicated socket is absent from Neovim RPC serverlist and private by default"] = function()
	start()
	MiniTest.expect.equality(child.lua_get(string.format([[vim.list_contains(vim.fn.serverlist(), %q)]], sock)), false)
	MiniTest.expect.equality(vim.uv.fs_stat(sock).mode % 512, tonumber("600", 8))
	local c = connect()
	send(c, request())
	local reply = response(c)
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.id, child.lua_get([[require("codeforge.state").changes[1].id]]))
	MiniTest.expect.equality(
		reply.result.files[1].hunks[1].id,
		child.lua_get([[require("codeforge.state").changes[1].files[1].hunks[1].id]])
	)
end

T["split JSON is not admitted until the newline and content is never evaluated"] = function()
	start()
	local p = proposal()
	p.files[1].hunks[1].lines = { "+vim.g.codeforge_execution_probe = true -- café\\ntext" }
	local frame = request(p)
	local c = connect()
	send(c, frame:sub(1, 30))
	child.lua([[vim.wait(30)]])
	unchanged()
	send(c, frame:sub(31, -2))
	child.lua([[vim.wait(30)]])
	unchanged()
	send(c, "\n")
	MiniTest.expect.equality(response(c).ok, true)
	MiniTest.expect.equality(child.lua_get([[vim.g.codeforge_execution_probe]]), vim.NIL)
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").changes[1].files[1].hunks[1].lines]]),
		p.files[1].hunks[1].lines
	)
end

for _, op in ipairs({
	"nvim_exec_lua",
	"nvim_command",
	"receive_file",
	"receive_file_strict",
	"setup_socket",
	"accept",
	"__index",
}) do
	T["operation allowlist refuses " .. op] = function()
		start()
		local c = connect()
		send(c, vim.json.encode({ op = op, proposal = proposal() }) .. "\n")
		local reply = response(c)
		MiniTest.expect.equality(reply.ok, false)
		MiniTest.expect.equality(reply.error.code, "unknown_operation")
		unchanged()
	end
end

T["native MessagePack RPC execution attempt is not interpreted"] = function()
	start({ request_timeout_ms = 100 })
	local c = connect()
	send(c, vim.mpack.encode({ 0, 1, "nvim_exec_lua", { "vim.g.codeforge_execution_probe = true", {} } }) .. "\n")
	MiniTest.expect.equality(response(c).ok, false)
	unchanged()
end

for _, raw in ipairs({
	"{bad json}",
	"null",
	"[]",
	"true",
	'{"op":"publish","proposal":null}',
	'{"method":"nvim_exec_lua","params":["vim.g.codeforge_execution_probe=true"]}',
}) do
	T["malformed request is isolated: " .. raw] = function()
		start()
		local c = connect()
		send(c, raw .. "\n")
		MiniTest.expect.equality(response(c).ok, false)
		unchanged()
		local good = connect()
		send(good, request())
		MiniTest.expect.equality(response(good).ok, true)
	end
end

T["publish does not smuggle extra operations or machinery-owned fields"] = function()
	start()
	local cases = {
		{ op = "publish", proposal = proposal(), lua = "vim.g.codeforge_execution_probe=true" },
		{ op = "publish", proposal = proposal(), path = "/etc/passwd" },
	}
	local poisoned = proposal()
	poisoned.files[1].atomic_baseline = { "injected baseline" }
	cases[#cases + 1] = { op = "publish", proposal = poisoned }
	for _, value in ipairs(cases) do
		local c = connect()
		send(c, vim.json.encode(value) .. "\n")
		MiniTest.expect.equality(response(c).ok, false)
		unchanged()
	end
end

T["malformed later file rejects the entire request"] = function()
	start()
	local p = proposal()
	p.files[2] = {
		path = "bad.lua",
		status = "modified",
		base = { "original" },
		hunks = {
			{
				old_start = 1,
				old_lines = 1,
				new_start = 1,
				new_lines = 1,
				lines = { "-wrong", "+new" },
			},
		},
	}
	local c = connect()
	send(c, request(p))
	local reply = response(c)
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	unchanged()
end

T["oversized complete and partial frames close without admission"] = function()
	start({ max_message_bytes = 256 })
	for _, ending in ipairs({ "", "\n" }) do
		local c = connect()
		send(c, string.rep(" ", 257) .. ending)
		MiniTest.expect.equality(response(c).error.code, "message_too_large")
		unchanged()
	end
end

T["frame at the byte limit is admitted but another request in the frame is rejected"] = function()
	local frame = request()
	start({ max_message_bytes = #frame - 1 })
	local c = connect()
	send(c, frame)
	MiniTest.expect.equality(response(c).ok, true)
	child.lua([[require("codeforge.state").reset()]])
	c = connect()
	send(c, frame .. frame)
	MiniTest.expect.equality(response(c).ok, false)
	unchanged()
end

T["incomplete clients expire without blocking another client"] = function()
	start({ request_timeout_ms = 100 })
	local slow = connect()
	send(slow, '{"op":')
	local good = connect()
	send(good, request())
	MiniTest.expect.equality(response(good).ok, true)
	MiniTest.expect.equality(response(slow).error.code, "timeout")
end

T["disconnect mid-request is discarded and capacity is recovered"] = function()
	start({ max_clients = 1 })
	local abandoned = connect()
	send(abandoned, request():sub(1, -2))
	abandoned.pipe:close()
	child.lua([[vim.wait(50)]])
	unchanged()
	local good = connect()
	send(good, request())
	MiniTest.expect.equality(response(good).ok, true)
end

T["excess connections are closed and shutdown cancels incomplete clients"] = function()
	start({ max_clients = 1 })
	local first = connect()
	send(first, "{")
	local excess = connect()
	await(function()
		return excess.eof
	end, "over-capacity connection was retained")
	child.lua([[require("codeforge.transport").setup_socket(false)]])
	await(function()
		return first.eof
	end, "shutdown leaked a client")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
	unchanged()
end

T["switching addresses closes the old listener and idempotent setup keeps the new one"] = function()
	start()
	local old = connect()
	send(old, "{")
	local next_sock = F.tmp_path("_next.sock")
	start({ path = next_sock })
	start({ path = next_sock })
	await(function()
		return old.eof
	end, "address switch retained old clients")
	MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
	local c = connect(next_sock)
	send(c, request())
	MiniTest.expect.equality(response(c).ok, true)
end

T["an existing native RPC endpoint is never adopted or chmodded"] = function()
	child.lua(string.format([[vim.fn.serverstart(%q)]], sock))
	local mode = vim.uv.fs_stat(sock).mode
	start({ mode = "666" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock).mode, mode)
	MiniTest.expect.equality(child.lua_get(string.format([[vim.list_contains(vim.fn.serverlist(), %q)]], sock)), true)
end

T["permission failure is fail-closed even when libuv returns nil instead of throwing"] = function()
	child.lua([[vim.uv.fs_chmod = function() return nil, "EPERM" end]])
	start()
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
end

T["unknown group refuses startup instead of exposing the wrong permissions"] = function()
	start({ group = "no-such-codeforge-group", mode = "660" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
end

T["excessive JSON nesting is rejected before decoding"] = function()
	start()
	local c = connect()
	send(c, string.rep("[", 70) .. "0" .. string.rep("]", 70) .. "\n")
	MiniTest.expect.equality(response(c).error.code, "invalid_request")
	unchanged()
end

T["default addresses remain platform-specific without starting RPC"] = function()
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.transport").socket_path()]]),
		child.fn.stdpath("run") .. "/codeforge.sock"
	)
	child.lua([[require("codeforge.transport")._is_windows = function() return true end]])
	local path = child.lua_get([[require("codeforge.transport").socket_path()]])
	local prefix = "\\\\.\\pipe\\codeforge-"
	MiniTest.expect.equality(path:sub(1, #prefix), prefix)
end

T["configured group and mode are applied before clients can connect"] = function()
	local group = child.fn.system({ "id", "-gn" }):gsub("%s+$", "")
	local gid = tonumber(child.fn.system({ "id", "-g" }))
	start({ group = group, mode = "660" })
	local stat = vim.uv.fs_stat(sock)
	MiniTest.expect.equality(stat.gid, gid)
	MiniTest.expect.equality(stat.mode % 512, tonumber("660", 8))
	local c = connect()
	send(c, request())
	MiniTest.expect.equality(response(c).ok, true)
end

T["group permission failure closes the listener"] = function()
	local group = child.fn.system({ "id", "-gn" }):gsub("%s+$", "")
	child.lua([[vim.uv.fs_chown = function() return nil, "EPERM" end]])
	start({ group = group, mode = "660" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
end

T["Windows group and mode options fail rather than pretend to enforce Unix permissions"] = function()
	child.lua([[require("codeforge.transport")._is_windows = function() return true end]])
	start({ mode = "660" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
end

T["invalid limits and permissions never start a listener"] = function()
	for _, opts in ipairs({
		{ max_message_bytes = 0 },
		{ max_message_bytes = 1048577 },
		{ max_clients = -1 },
		{ max_clients = 1.5 },
		{ request_timeout_ms = 0 },
		{ mode = "888" },
		{ mode = 660 },
		{ surprise = true },
	}) do
		start(opts)
		MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
		MiniTest.expect.equality(vim.uv.fs_stat(sock), nil)
	end
end

T["binding an existing regular file does not remove or chmod it"] = function()
	child.lua(string.format([[vim.fn.writefile({"keep me"}, %q)]], sock))
	local before = vim.uv.fs_stat(sock)
	start({ mode = "666" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), vim.NIL)
	MiniTest.expect.equality(vim.uv.fs_stat(sock).mode, before.mode)
	MiniTest.expect.equality(child.fn.readfile(sock), { "keep me" })
end

T["stop and immediate restart at the same path retain a usable listener"] = function()
	start()
	child.lua(string.format(
		[[
		local t = require("codeforge.transport")
		assert(t.setup_socket(false))
		assert(t.setup_socket(%q))
	]],
		sock
	))
	local c = connect()
	send(c, request())
	MiniTest.expect.equality(response(c).ok, true)
end

T["changing options at the same path requires an explicit stop"] = function()
	start()
	start({ mode = "666" })
	MiniTest.expect.equality(vim.uv.fs_stat(sock).mode % 512, tonumber("600", 8))
	local c = connect()
	send(c, request())
	MiniTest.expect.equality(response(c).ok, true)
end

T["handler exceptions do not escape callbacks or disable the listener"] = function()
	start()
	child.lua([[
		_G.__original_receive = require("codeforge.transport").receive
		require("codeforge.transport").receive = function() error("private stack information") end
	]])
	local c = connect()
	send(c, request())
	local reply = response(c)
	MiniTest.expect.equality(reply.error.code, "internal_error")
	MiniTest.expect.equality(reply.error.message:find("private", 1, true), nil)
	unchanged()
	child.lua([[require("codeforge.transport").receive = _G.__original_receive]])
	c = connect()
	send(c, request())
	MiniTest.expect.equality(response(c).ok, true)
end

T["failed address switch leaves the working listener intact"] = function()
	start()
	start({ path = sock .. "/missing/child.sock" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").active_socket]]), sock)
	local c = connect()
	send(c, request())
	MiniTest.expect.equality(response(c).ok, true)
end

T["shutdown cancels a request queued for main-loop admission"] = function()
	start()
	child.lua([[
		_G.__scheduled = {}
		_G.__real_schedule = vim.schedule
		vim.schedule = function(fn) table.insert(_G.__scheduled, fn) end
	]])
	local c = connect()
	send(c, request())
	await(function()
		return child.lua_get([[#_G.__scheduled]]) > 0
	end, "admission was not queued")
	child.lua([[
		require("codeforge.transport").setup_socket(false)
		vim.schedule = _G.__real_schedule
		for _, fn in ipairs(_G.__scheduled) do fn() end
	]])
	await(function()
		return c.eof
	end, "queued client's socket was not closed")
	unchanged()
end

T["invalid numeric geometry and NUL paths are refused on the wire"] = function()
	start()
	local p = proposal()
	p.files[1].path = "bad\0path"
	local c = connect()
	send(c, request(p))
	MiniTest.expect.equality(response(c).error.code, "invalid_proposal")
	c = connect()
	local frame = request():gsub('"new_start":1', '"new_start":1e999')
	send(c, frame)
	MiniTest.expect.equality(response(c).ok, false)
	unchanged()
end

T["file and hunk counts are bounded independently of frame size"] = function()
	start()
	local p = proposal()
	for i = 2, 129 do
		p.files[i] = proposal("f" .. i .. ".lua").files[1]
	end
	local c = connect()
	send(c, request(p))
	MiniTest.expect.equality(response(c).error.code, "invalid_proposal")
	p = proposal()
	for i = 2, 1025 do
		p.files[1].hunks[i] = vim.deepcopy(p.files[1].hunks[1])
	end
	c = connect()
	send(c, request(p))
	MiniTest.expect.equality(response(c).error.code, "invalid_proposal")
	unchanged()
end

T["brackets and escaped quotes inside strings do not count as JSON nesting"] = function()
	start()
	local p = proposal()
	p.title = string.rep('[{\\"', 100)
	local c = connect()
	send(c, request(p))
	MiniTest.expect.equality(response(c).ok, true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].title]]), p.title)
end

T["status over the socket reports pending and completed outcomes without exposing file content"] = function()
	start()
	local path = F.tmp_path()
	child.api.nvim_set_current_dir(child.fn.fnamemodify(path, ":h"))
	child.fn.writefile({ "original" }, path)
	child.lua([[require("codeforge.state").log_file = nil]])
	local p = {
		files = {
			{
				path = path,
				status = "modified",
				base = { "original" },
				hunks = {
					{
						old_start = 1,
						old_lines = 1,
						new_start = 1,
						new_lines = 1,
						lines = { "-original", "+proposal" },
					},
				},
			},
		},
	}
	local c = connect()
	send(c, request(p))
	local ack = response(c).result

	for _, outcome in ipairs({ "pending", "rejected" }) do
		if outcome == "rejected" then
			child.lua(string.format(
				[[
				require("codeforge.review.buffer").open(%q)
				require("codeforge.state").get_review(%q):reject_hunk(0)
			]],
				path,
				path
			))
		end
		c = connect()
		send(c, vim.json.encode({ op = "status", id = ack.id }) .. "\n")
		MiniTest.expect.equality(response(c), {
			ok = true,
			result = {
				id = ack.id,
				status = outcome,
				under_review = outcome == "pending",
				files = {
					{
						path = path,
						status = "modified",
						modified = false,
						hunks = { { id = ack.files[1].hunks[1].id, status = outcome } },
					},
				},
			},
		})
	end
	MiniTest.expect.equality(child.fn.readfile(path), { "original" })
end

T["bad status requests are isolated and cannot publish or invoke Neovim operations"] = function()
	start()
	for _, value in ipairs({
		{ op = "status", id = "unknown", expected = "not_found" },
		{ op = "status", id = {}, expected = "invalid_request" },
		{ op = "status", id = "unknown", proposal = proposal(), expected = "invalid_request" },
		{ op = "status", id = "unknown", lua = "vim.g.codeforge_execution_probe=true", expected = "invalid_request" },
	}) do
		local expected = value.expected
		value.expected = nil
		local c = connect()
		send(c, vim.json.encode(value) .. "\n")
		local reply = response(c)
		MiniTest.expect.equality(reply.ok, false)
		MiniTest.expect.equality(reply.error.code, expected)
		unchanged()
	end
	local good = connect()
	send(good, request())
	MiniTest.expect.equality(response(good).ok, true)
end

T["publish rejects a foreign checkout atomically and accepts editor-relative paths afterwards"] = function()
	start()
	local foreign = child.fn.getcwd() .. "/foreign.lua"
	local root = child.fn.fnamemodify(sock, ":h")
	child.api.nvim_set_current_dir(root)
	local p = proposal("valid.lua")
	p.files[2] = proposal(foreign).files[1]
	local c = connect()
	send(c, request(p))
	local reply = response(c)
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(reply.error.message:find("outside Neovim working directory", 1, true) ~= nil, true)
	unchanged()
	c = connect()
	send(c, request(proposal("nested/new.lua")))
	reply = response(c)
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.files[1].path, root .. "/nested/new.lua")
end

T["a missing modification is refused on the wire until the receiving file exists"] = function()
	start()
	local root = child.fn.fnamemodify(sock, ":h")
	child.api.nvim_set_current_dir(root)
	local p = {
		files = {
			{
				path = "missing.lua",
				status = "modified",
				base = { "original" },
				hunks = {
					{
						old_start = 1,
						old_lines = 1,
						new_start = 1,
						new_lines = 1,
						lines = { "-original", "+proposal" },
					},
				},
			},
		},
	}
	local c = connect()
	send(c, request(p))
	local reply = response(c)
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(reply.error.message:find("must already exist", 1, true) ~= nil, true)
	MiniTest.expect.equality(child.fn.filereadable(root .. "/missing.lua"), 0)
	unchanged()

	child.fn.writefile({ "original" }, root .. "/missing.lua")
	c = connect()
	send(c, request(p))
	reply = response(c)
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.files[1].path, root .. "/missing.lua")
	MiniTest.expect.equality(child.fn.readfile(root .. "/missing.lua"), { "original" })
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
end

T["info over the socket reports the resolved cwd a client must publish against"] = function()
	start()
	-- Reach the project through a symlink, so the reply can be checked for a
	-- *normalized, resolved* directory rather than whatever string was chdir'd
	-- to. Neovim's getcwd() already resolves symlinks; `info` must keep that
	-- property, since publish's containment check compares resolved paths.
	local real = child.fn.fnamemodify(sock, ":h")
	local link = child.fn.tempname() .. "_link"
	child.fn.system({ "ln", "-sfn", real, link })
	child.api.nvim_set_current_dir(link)

	local c = connect()
	send(c, vim.json.encode({ op = "info" }) .. "\n")
	local reply = response(c)
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.cwd, child.fn.fnamemodify(real, ":p"):gsub("/$", ""))
	MiniTest.expect.equality(reply.result.cwd:find("_link", 1, true) == nil, true, {
		fail_reason = "the reported cwd must be resolved, not the symlink used to enter it",
	})
	-- The reported cwd is exactly the containment root publish enforces: a
	-- path built from it is admitted.
	local p = proposal(reply.result.cwd .. "/nested/info-target.lua")
	local pub = connect()
	send(pub, request(p))
	local acked = response(pub)
	MiniTest.expect.equality(acked.ok, true)
	MiniTest.expect.equality(acked.result.files[1].path, reply.result.cwd .. "/nested/info-target.lua")
end

T["info over the socket names the live socket address"] = function()
	start()
	local c = connect()
	send(c, vim.json.encode({ op = "info" }) .. "\n")
	MiniTest.expect.equality(response(c).result.socket, sock)
end

T["hunk descriptions travel over the socket and are renderable"] = function()
	start()
	local root = child.fn.fnamemodify(sock, ":h")
	child.api.nvim_set_current_dir(root)
	local p = proposal("described.lua")
	p.files[1].hunks[1].description = "Return a greeting"
	local c = connect()
	send(c, request(p))
	MiniTest.expect.equality(response(c).ok, true)
	MiniTest.expect.equality(
		child.lua_get([=[require("codeforge.state").changes[1].files[1].hunks[1].description]=]),
		"Return a greeting"
	)
end

return T
