do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

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

---Write a change-set JSON file in the child (returns the path).
---@param content? string raw file content (default: a valid one-file change-set)
local function write_json(content)
	local path = F.tmp_path("_change.json")
	if content == nil then
		content = vim.json.encode({
			id = "e2e-1",
			title = "Delivered change",
			files = {
				{
					path = "e2e_target.lua",
					status = "added",
					hunks = {
						{ id = "h", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+hello" } },
					},
				},
			},
		})
	end
	child.lua(
		string.format(
			[[vim.fn.writefile(vim.split(%s, "\n", { plain = true }), %s)]],
			vim.inspect(content),
			vim.inspect(path)
		)
	)
	return path
end

---Evaluate a child-side expression returning two values (captured via _G,
---since lua_get crosses only one value).
local function call2(expr)
	child.lua(string.format(
		[[local a, b = %s
                _G.__a, _G.__b = a, b]],
		expr
	))
	return child.lua_get([[_G.__a]]), child.lua_get([[_G.__b]])
end

-- ── socket lifecycle ───────────────────────────────────────────────────────

T["socket_path defaults to the run dir before any socket starts"] = function()
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.transport").socket_path()]]),
		child.fn.stdpath("run") .. "/codeforge.sock"
	)
end

T["setup_socket starts a server at the given address"] = function()
	local sock = F.tmp_path("_rpc.sock")
	child.lua(string.format([[require("codeforge.transport").setup_socket(%s)]], vim.inspect(sock)))
	MiniTest.expect.equality(
		child.lua_get(string.format([[vim.list_contains(vim.fn.serverlist(), %s)]], vim.inspect(sock))),
		true,
		{ fail_reason = "serverlist should contain the started socket" }
	)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").socket_path()]]), sock)
end

T["setup_socket is idempotent for the same address"] = function()
	local sock = F.tmp_path("_rpc.sock")
	child.lua(string.format(
		[[require("codeforge.transport").setup_socket(%s)
                require("codeforge.transport").setup_socket(%s)]],
		vim.inspect(sock),
		vim.inspect(sock)
	))
	MiniTest.expect.equality(
		child.lua_get(string.format(
			[[(function()
                                local n = 0
                                for _, a in ipairs(vim.fn.serverlist()) do
                                        if a == %s then n = n + 1 end
                                end
                                return n
                        end)()]],
			vim.inspect(sock)
		)),
		1,
		{ fail_reason = "starting twice must not create two servers" }
	)
end

T["setup_socket(false) stops the socket"] = function()
	local sock = F.tmp_path("_rpc.sock")
	child.lua(string.format([[require("codeforge.transport").setup_socket(%s)]], vim.inspect(sock)))
	MiniTest.expect.equality(child.lua_get([[require("codeforge.transport").socket_path()]]), sock)
	child.lua([[require("codeforge.transport").setup_socket(false)]])
	MiniTest.expect.equality(
		child.lua_get(string.format([[vim.list_contains(vim.fn.serverlist(), %s)]], vim.inspect(sock))),
		false,
		{ fail_reason = "the socket should be stopped" }
	)
end

-- ── JSON delivery ──────────────────────────────────────────────────────────

T["receive_json ingests a valid change-set"] = function()
	local json = write_json()
	local ok, ack =
		call2(string.format([[require("codeforge.transport").receive_json(vim.fn.readfile(%s)[1])]], vim.inspect(json)))
	MiniTest.expect.equality(ok, true)
	MiniTest.expect.equality(ack, "received change e2e-1 (1 file)")
	MiniTest.expect.equality(#child.lua_get([[require("codeforge.state").get_changes()]]), 1)
end

T["receive_json rejects malformed JSON"] = function()
	local ok, err = call2([[require("codeforge.transport").receive_json("{not json")]])
	MiniTest.expect.equality(ok, false)
	MiniTest.expect.equality(err:find("JSON", 1, true) ~= nil, true)
end

T["receive_json surfaces validation errors from receive"] = function()
	local ok, err = call2([[require("codeforge.transport").receive_json(vim.json.encode({ files = {} }))]])
	MiniTest.expect.equality(ok, false)
	MiniTest.expect.equality(err:find("id", 1, true) ~= nil, true)
end

-- ── file delivery ──────────────────────────────────────────────────────────

T["receive_file ingests a JSON file"] = function()
	local json = write_json()
	local ok, ack = call2(string.format([[require("codeforge.transport").receive_file(%s)]], vim.inspect(json)))
	MiniTest.expect.equality(ok, true)
	MiniTest.expect.equality(ack, "received change e2e-1 (1 file)")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_changes()[1].id]]), "e2e-1")
end

T["receive_file accepts pretty-printed JSON"] = function()
	local json = write_json(
		'{\n  "id": "pretty-1",\n  "files": [\n    {\n      "path": "p.lua",\n'
			.. '      "status": "added",\n      "hunks": [ { "id": "h", "old_start": 1, "old_lines": 0,\n'
			.. '        "new_start": 1, "new_lines": 1, "lines": [ "+x" ] } ]\n    } ]\n}\n'
	)
	local ok =
		child.lua_get(string.format([[select(1, require("codeforge.transport").receive_file(%s))]], vim.inspect(json)))
	MiniTest.expect.equality(ok, true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_changes()[1].id]]), "pretty-1")
end

T["receive_file reports a missing file"] = function()
	local missing = F.tmp_path("_absent.json")
	local ok, err = call2(string.format([[require("codeforge.transport").receive_file(%s)]], vim.inspect(missing)))
	MiniTest.expect.equality(ok, false)
	MiniTest.expect.equality(err:find(missing, 1, true) ~= nil, true)
end

T["receive_file reports invalid JSON content"] = function()
	local json = write_json("garbage {")
	local ok, err = call2(string.format([[require("codeforge.transport").receive_file(%s)]], vim.inspect(json)))
	MiniTest.expect.equality(ok, false)
	MiniTest.expect.equality(err:find("JSON", 1, true) ~= nil, true)
end

-- ── autoload bridge (used by `nvim --remote-expr`) ─────────────────────────

T["codeforge#receive returns the ack string"] = function()
	local json = write_json()
	local ack = child.lua_get(string.format([[vim.fn["codeforge#receive"](%s)]], vim.inspect(json)))
	MiniTest.expect.equality(ack, "received change e2e-1 (1 file)")
end

T["codeforge#receive throws on invalid input"] = function()
	local json = write_json("garbage {")
	local ok, err = call2(string.format([[pcall(vim.fn["codeforge#receive"], %s)]], vim.inspect(json)))
	MiniTest.expect.equality(ok, false)
	MiniTest.expect.equality(err:find("JSON", 1, true) ~= nil, true)
end

-- ── end-to-end: external nvim client over the socket ───────────────────────

T["an external nvim client delivers a change over the socket"] = function()
	local sock = F.tmp_path("_rpc.sock")
	child.lua(string.format([[require("codeforge.transport").setup_socket(%s)]], vim.inspect(sock)))
	local json = write_json()
	local escaped = json:gsub("'", "'\\''")
	-- The client must be spawned asynchronously: a blocking wait in the child
	-- starves the child's event loop, which must stay free to accept the
	-- client's connection (deadlock otherwise). Polling from the host pumps
	-- the child's loop via RPC.
	child.lua(string.format(
		[[
                _G.__e2e_done, _G.__e2e_res = false, nil
                vim.system({ vim.v.progpath, "--clean", "--server", %s,
                        "--remote-expr", "codeforge#receive('%s')" },
                        { text = true, timeout = 15000 },
                        function(r) _G.__e2e_res, _G.__e2e_done = r, true end)
                ]],
		vim.inspect(sock),
		escaped
	))
	local done = false
	for _ = 1, 100 do
		if child.lua_get([[_G.__e2e_done]]) then
			done = true
			break
		end
		vim.uv.sleep(50)
	end
	MiniTest.expect.equality(done, true, { fail_reason = "the client job never finished" })
	local code = child.lua_get([[_G.__e2e_res.code]])
	local out = child.lua_get([[_G.__e2e_res.stdout]])
	MiniTest.expect.equality(code, 0, { fail_reason = "remote-expr should succeed; got: " .. tostring(out) })
	MiniTest.expect.equality(out:find("received change e2e%-1", 1, false) ~= nil, true, {
		fail_reason = "client should see the ack; got: " .. tostring(out),
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_changes()[1].id]]), "e2e-1", {
		fail_reason = "the change should be ingested in the running instance",
	})
end

return T
