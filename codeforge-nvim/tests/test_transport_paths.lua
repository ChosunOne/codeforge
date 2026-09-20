do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures")
F.set_child(child)
local sandbox, root, outside, original_cwd

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			original_cwd = child.fn.getcwd()
			sandbox = F.tmp_path("_scope")
			root, outside = sandbox .. "/project", sandbox .. "/project-other"
			child.fn.mkdir(root, "p")
			child.fn.mkdir(outside, "p")
			child.api.nvim_set_current_dir(root)
			child.lua([[
				local state = require("codeforge.state")
				state.reset()
				state.log_file = nil
			]])
		end,
		post_case = function()
			child.api.nvim_set_current_dir(original_cwd)
			child.fn.delete(sandbox, "rf")
			F.cleanup()
		end,
		post_once = child.stop,
	},
})

local function proposal(paths)
	local files = {}
	for _, path in ipairs(paths) do
		files[#files + 1] = {
			path = path,
			status = "added",
			hunks = { { old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+new" } } },
		}
	end
	return { files = files }
end

local function receive(paths)
	return child.lua_get(string.format(
		[[(function()
		local ok, result = require("codeforge.transport").receive(%s)
		return { ok = ok, result = result }
	end)()]],
		vim.inspect(proposal(paths))
	))
end

local function expect_rejected(paths)
	child.lua([[
		local state = require("codeforge.state")
		before = { changes = vim.deepcopy(state.changes), buffers = vim.api.nvim_list_bufs() }
		state.set_on_change(function() error("invalid path must not refresh") end)
		vim.uv.random = function() error("invalid path must not allocate an identity") end
	]])
	local reply = receive(paths)
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(type(reply.result), "string")
	MiniTest.expect.equality(reply.result:find("path", 1, true) ~= nil, true)
	MiniTest.expect.equality(
		child.lua_get([[(function()
		local state = require("codeforge.state")
		return vim.deep_equal(before.changes, state.changes)
			and vim.deep_equal(before.buffers, vim.api.nvim_list_bufs())
			and next(state.reviews) == nil and #state.log == 0
	end)()]]),
		true
	)
	return reply.result
end

T["absolute paths from another checkout reject the entire proposal before admission"] = function()
	local err = expect_rejected({ "valid.lua", outside .. "/foreign.lua" })
	MiniTest.expect.equality(err:find("outside Neovim working directory", 1, true) ~= nil, true)
end

T["parent traversal cannot escape and sibling prefix is not containment"] = function()
	expect_rejected({ "../project-other/new.lua" })
	expect_rejected({ root .. "-other/new.lua" })
end

T["relative and absolute in-root files with nonexistent parents are admitted"] = function()
	local reply = receive({ "new/deep/file.lua", root .. "/absolute.lua" })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.files[1].path, root .. "/new/deep/file.lua")
	MiniTest.expect.equality(reply.result.files[2].path, root .. "/absolute.lua")
	MiniTest.expect.equality(child.fn.isdirectory(root .. "/new"), 0)
	MiniTest.expect.equality(child.fn.filereadable(root .. "/absolute.lua"), 0)
end

T["the working directory itself is not a file target"] = function()
	expect_rejected({ "." })
	expect_rejected({ root })
end

T["a changed editor cwd is used for each publication, not cached from setup"] = function()
	child.api.nvim_set_current_dir(outside)
	expect_rejected({ root .. "/old-root.lua" })
end

T["the wire reports invalid_proposal for an out-of-root path"] = function()
	local reply = child.lua_get(
		string.format(
			[[require("codeforge.protocol").handle(%q)]],
			vim.json.encode({ op = "publish", proposal = proposal({ outside .. "/foreign.lua" }) })
		)
	)
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
end

local function symlink(target, link, directory)
	if child.fn.has("win32") == 1 then
		MiniTest.skip("symlink fixtures require Unix")
	end
	child.lua(
		string.format([[assert(vim.uv.fs_symlink(%q, %q, %s))]], target, link, directory and "{ dir = true }" or "{}")
	)
end

T["an existing file symlink cannot target another checkout"] = function()
	child.fn.writefile({ "outside" }, outside .. "/target.lua")
	symlink(outside .. "/target.lua", root .. "/link.lua")
	expect_rejected({ "link.lua" })
end

T["missing descendants of an escaping directory symlink are rejected"] = function()
	symlink(outside, root .. "/linked", true)
	expect_rejected({ "linked/missing/deep/new.lua" })
end

T["dangling symlinks fail closed rather than becoming imaginary in-root files"] = function()
	symlink(outside .. "/missing", root .. "/broken", true)
	expect_rejected({ "broken/new.lua" })
end

T["symlink cycles fail closed"] = function()
	symlink(root .. "/b", root .. "/a")
	symlink(root .. "/a", root .. "/b")
	expect_rejected({ "a" })
end

T["in-root symlink aliases use the canonical target and cannot create duplicate reviews"] = function()
	child.fn.mkdir(root .. "/real", "p")
	symlink(root .. "/real", root .. "/alias", true)
	local reply = receive({ "alias/new.lua" })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.files[1].path, root .. "/real/new.lua")
	local duplicate = receive({ "real/new.lua" })
	MiniTest.expect.equality(duplicate.ok, false)
	MiniTest.expect.equality(duplicate.result:find("already tracked", 1, true) ~= nil, true)
end

T["canonical aliases within one proposal are rejected before identity allocation"] = function()
	child.fn.mkdir(root .. "/real", "p")
	symlink(root .. "/real", root .. "/alias", true)
	expect_rejected({ "real/new.lua", "alias/new.lua" })
end

T["an unresolvable path is not treated as a merely nonexistent child"] = function()
	child.lua([[
		local realpath = vim.uv.fs_realpath
		vim.uv.fs_realpath = function(path)
			if path:match("/denied$") then
				return nil, "permission denied", "EACCES"
			end
			return realpath(path)
		end
	]])
	expect_rejected({ "denied" })
end

T["a symlinked working directory still admits its own relative files"] = function()
	symlink(root, sandbox .. "/worktree-alias", true)
	child.api.nvim_set_current_dir(sandbox .. "/worktree-alias")
	local reply = receive({ "new.lua" })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.files[1].path, root .. "/new.lua")
end

return T
