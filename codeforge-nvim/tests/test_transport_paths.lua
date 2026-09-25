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

local function modified_file(path)
	return {
		path = path,
		status = "modified",
		base = { "original" },
		hunks = { { old_start = 1, old_lines = 1, new_start = 1, new_lines = 1, lines = { "-original", "+proposal" } } },
	}
end

local function publish_files(files)
	return child.lua_get(
		string.format(
			[[require("codeforge.protocol").handle(%q)]],
			vim.json.encode({ op = "publish", proposal = { files = files } })
		)
	)
end

T["a missing modified file rejects a mixed batch without admitting earlier files or allocating IDs"] = function()
	local before = receive({ "already-pending.lua" })
	MiniTest.expect.equality(before.ok, true)
	child.lua([[
		local state = require("codeforge.state")
		before_changes = vim.deepcopy(state.changes)
		before_buffers = vim.api.nvim_list_bufs()
		state.set_on_change(function() error("invalid batch must not refresh") end)
		-- Force a fresh identity prefix so an allocation attempt cannot hide in a cache.
		package.loaded["codeforge.transport"] = nil
		vim.uv.random = function() error("invalid batch must not allocate IDs") end
	]])
	local reply = publish_files({ proposal({ "valid-new.lua" }).files[1], modified_file("missing.lua") })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(reply.error.message:find("missing.lua", 1, true) ~= nil, true)
	MiniTest.expect.equality(reply.error.message:find("must already exist", 1, true) ~= nil, true)
	MiniTest.expect.equality(
		child.lua_get([[vim.deep_equal(before_changes, require("codeforge.state").changes)]]),
		true
	)
	MiniTest.expect.equality(child.lua_get([[vim.deep_equal(before_buffers, vim.api.nvim_list_bufs())]]), true)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
	MiniTest.expect.equality(child.fn.filereadable(root .. "/valid-new.lua"), 0)
	MiniTest.expect.equality(child.fn.filereadable(root .. "/missing.lua"), 0)
end

T["modified targets under missing directories are not implicitly treated as added files"] = function()
	local reply = publish_files({ modified_file(root .. "/missing/deep/file.lua") })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(child.fn.isdirectory(root .. "/missing"), 0)
end

T["an existing directory is not a valid modification target"] = function()
	child.fn.mkdir(root .. "/directory", "p")
	local reply = publish_files({ modified_file("directory") })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(reply.error.message:find("regular file", 1, true) ~= nil, true)
end

T["an unsaved buffer alone does not make a modified file exist on disk"] = function()
	child.cmd("edit " .. root .. "/unsaved.lua")
	child.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved user content" })
	local reply = publish_files({ modified_file("unsaved.lua") })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	MiniTest.expect.equality(child.api.nvim_buf_get_lines(0, 0, -1, false), { "unsaved user content" })
	MiniTest.expect.equality(child.fn.filereadable(root .. "/unsaved.lua"), 0)
end

T["existing files need not match the supplied base and are not loaded or overwritten on admission"] = function()
	child.fn.writefile({ "user's disk edits" }, root .. "/existing.lua")
	local buffers = child.api.nvim_list_bufs()
	local reply = publish_files({ modified_file("existing.lua") })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(child.api.nvim_list_bufs(), buffers)
	MiniTest.expect.equality(child.fn.readfile(root .. "/existing.lua"), { "user's disk edits" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].files[1].base]]), { "original" })
end

T["an existing empty file can be modified by an insertion"] = function()
	child.fn.writefile({}, root .. "/empty.lua")
	local file = proposal({ "empty.lua" }).files[1]
	file.status, file.base = "modified", {}
	local reply = publish_files({ file })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(child.fn.getfsize(root .. "/empty.lua"), 0)
end

T["an in-root symlink to an existing regular file remains a valid modification target"] = function()
	child.fn.writefile({ "original" }, root .. "/existing.lua")
	symlink(root .. "/existing.lua", root .. "/alias.lua")
	local reply = publish_files({ modified_file("alias.lua") })
	MiniTest.expect.equality(reply.ok, true)
	MiniTest.expect.equality(reply.result.files[1].path, root .. "/existing.lua")
end

T["failure to stat a modified target fails closed rather than assuming it exists"] = function()
	child.fn.writefile({ "original" }, root .. "/unverifiable.lua")
	child.lua([[
		local stat = vim.uv.fs_stat
		vim.uv.fs_stat = function(path)
			if path:match("/unverifiable.lua$") then
				return nil, "permission denied", "EACCES"
			end
			return stat(path)
		end
	]])
	local reply = publish_files({ modified_file("unverifiable.lua") })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
end

T["every refused path is named in one reply, not only the first"] = function()
	local reply = publish_files({
		modified_file("missing-a.lua"),
		modified_file("missing-b.lua"),
		modified_file("missing-c.lua"),
	})
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	for _, name in ipairs({ "missing-a.lua", "missing-b.lua", "missing-c.lua" }) do
		MiniTest.expect.equality(reply.error.message:find(name, 1, true) ~= nil, true, {
			fail_reason = name .. " must be named; got: " .. reply.error.message,
		})
	end
end

T["each refused path keeps its own reason"] = function()
	-- Distinct causes must stay distinguishable: an agent fixing one problem
	-- should not have to guess whether the others share it.
	local reply = publish_files({
		modified_file("missing.lua"),
		proposal({ outside .. "/foreign.lua" }).files[1],
	})
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.message:find("missing.lua", 1, true) ~= nil, true)
	MiniTest.expect.equality(reply.error.message:find("must already exist", 1, true) ~= nil, true)
	MiniTest.expect.equality(
		reply.error.message:find("outside Neovim working directory", 1, true) ~= nil,
		true,
		{ fail_reason = "got: " .. reply.error.message }
	)
end

T["paths are reported in request order"] = function()
	local reply = publish_files({
		modified_file("zzz-first.lua"),
		modified_file("aaa-second.lua"),
	})
	local msg = reply.error.message
	local first = msg:find("zzz-first.lua", 1, true)
	local second = msg:find("aaa-second.lua", 1, true)
	MiniTest.expect.equality(first ~= nil and second ~= nil, true, { fail_reason = "got: " .. msg })
	MiniTest.expect.equality(first < second, true, {
		fail_reason = "message must follow request order, not an incidental sort: " .. msg,
	})
end

T["a single refused path keeps its exact original message"] = function()
	-- Backward compatibility: nothing about the single-failure case changes.
	local reply = publish_files({ modified_file("solo-missing.lua") })
	MiniTest.expect.equality(
		reply.error.message,
		("path %q: modified target must already exist as a regular file on disk"):format("solo-missing.lua")
	)
end

T["a long refusal list stays bounded and states the true count"] = function()
	-- The error message has a byte budget. Exceeding it must disclose how many
	-- entries were omitted rather than silently dropping them.
	local files = {}
	local n = 60
	for i = 1, n do
		files[#files + 1] = modified_file(("missing-%03d-with-a-deliberately-long-name.lua"):format(i))
	end
	local reply = publish_files(files)
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.code, "invalid_proposal")
	local msg = reply.error.message
	MiniTest.expect.equality(#msg <= 4096, true, {
		fail_reason = "the message must stay within the 4096-byte cap, got " .. #msg,
	})
	MiniTest.expect.equality(msg:find(tostring(n), 1, true) ~= nil, true, {
		fail_reason = "the true failure count must appear, got: " .. msg:sub(1, 160),
	})
	MiniTest.expect.equality(msg:find("more", 1, true) ~= nil, true, {
		fail_reason = "omitted entries must be disclosed, got tail: " .. msg:sub(-160),
	})
end

T["a multi-path refusal admits nothing and allocates no identity"] = function()
	child.lua([[
		local state = require("codeforge.state")
		state.set_on_change(function() error("a refusal must not refresh the sidebar") end)
		vim.uv.random = function() error("a refusal must not allocate an identity") end
	]])
	local reply = publish_files({ modified_file("m1.lua"), modified_file("m2.lua") })
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)
	MiniTest.expect.equality(child.fn.filereadable(root .. "/m1.lua"), 0)
	MiniTest.expect.equality(child.fn.filereadable(root .. "/m2.lua"), 0)
end

T["several paths already under review are all named at once"] = function()
	local first = receive({ "tracked-a.lua", "tracked-b.lua" })
	MiniTest.expect.equality(first.ok, true)
	local reply = publish_files({
		proposal({ "tracked-a.lua" }).files[1],
		proposal({ "tracked-b.lua" }).files[1],
	})
	MiniTest.expect.equality(reply.ok, false)
	MiniTest.expect.equality(reply.error.message:find("tracked-a.lua", 1, true) ~= nil, true, {
		fail_reason = "got: " .. reply.error.message,
	})
	MiniTest.expect.equality(reply.error.message:find("tracked-b.lua", 1, true) ~= nil, true, {
		fail_reason = "got: " .. reply.error.message,
	})
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1, {
		fail_reason = "the refusal must not admit a second change",
	})
end

return T
