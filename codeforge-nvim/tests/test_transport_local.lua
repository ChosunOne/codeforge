-- Trusted in-editor compatibility helpers. These are not socket operations;
-- wire-level isolation/lifecycle tests live in test_transport_socket.lua.
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
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

local function write_json(content)
	local path = F.tmp_path("_change.json")
	content = content
		or vim.json.encode({
			title = "Delivered change",
			files = {
				{
					path = "e2e_target.lua",
					status = "added",
					hunks = {
						{
							old_start = 1,
							old_lines = 0,
							new_start = 1,
							new_lines = 1,
							lines = { "+hello" },
						},
					},
				},
			},
		})
	child.lua(
		string.format(
			[[vim.fn.writefile(vim.split(%s, "\n", { plain = true }), %s)]],
			vim.inspect(content),
			vim.inspect(path)
		)
	)
	return path
end

local function call2(expr)
	child.lua(string.format([[local a, b = %s; _G.__a, _G.__b = a, b]], expr))
	return child.lua_get([[_G.__a]]), child.lua_get([[_G.__b]])
end

local function expect_ack(ack)
	local change = child.lua_get([[require("codeforge.state").changes[1] ]])
	MiniTest.expect.equality(type(ack), "table")
	MiniTest.expect.equality(type(ack.id), "string")
	MiniTest.expect.equality(#ack.id > 0, true)
	MiniTest.expect.equality(ack, {
		id = change.id,
		files = { { path = change.files[1].path, hunks = { { id = change.files[1].hunks[1].id } } } },
	})
end

T["receive_json ingests a valid change-set"] = function()
	local json = write_json()
	local ok, ack =
		call2(string.format([[require("codeforge.transport").receive_json(vim.fn.readfile(%s)[1])]], vim.inspect(json)))
	MiniTest.expect.equality(ok, true)
	expect_ack(ack)
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
	MiniTest.expect.equality(err:find("files", 1, true) ~= nil, true)
end

T["receive_file ingests a JSON file"] = function()
	local json = write_json()
	local ok, ack = call2(string.format([[require("codeforge.transport").receive_file(%s)]], vim.inspect(json)))
	MiniTest.expect.equality(ok, true)
	expect_ack(ack)
end

T["receive_file accepts pretty-printed JSON"] = function()
	local json = write_json(
		'{\n  "title": "pretty",\n  "files": [\n    {\n      "path": "p.lua",\n'
			.. '      "status": "added",\n      "hunks": [ { "old_start": 1, "old_lines": 0,\n'
			.. '        "new_start": 1, "new_lines": 1, "lines": [ "+x" ] } ]\n    } ]\n}\n'
	)
	local ok =
		child.lua_get(string.format([[select(1, require("codeforge.transport").receive_file(%s))]], vim.inspect(json)))
	MiniTest.expect.equality(ok, true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_changes()[1].title]]), "pretty")
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

T["codeforge#receive returns a structured receipt locally"] = function()
	local json = write_json()
	local ack = child.lua_get(string.format([[vim.fn["codeforge#receive"](%s)]], vim.inspect(json)))
	expect_ack(ack)
end

T["codeforge#receive throws on invalid input"] = function()
	local json = write_json("garbage {")
	local ok, err = call2(string.format([[pcall(vim.fn["codeforge#receive"], %s)]], vim.inspect(json)))
	MiniTest.expect.equality(ok, false)
	MiniTest.expect.equality(err:find("JSON", 1, true) ~= nil, true)
end

return T
