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

-- NOTE: unlike the rest of the suite, these tests intentionally use real
-- on-disk files: the bug class they guard (E13 "File exists" on :w) only
-- exists for real files with real write semantics.

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.lua("require('codeforge.state').reset()")
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

---Seed a one-file change for a real temp file and open its review.
local function review_real_file(path)
	local base = { "local a = 1", "local b = 2" }
	child.fn.writefile(base, path)
	F.seed_change(path, base, { F.replace_hunk("h1", 2, "local b = 2", "local b = 20") })
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
end

---Accept every pending hunk (completes + dismisses the review).
local function complete_review(path)
	child.lua(string.format(
		[[
		local review = require("codeforge.state").get_review(%s)
		review:accept_pending()
		require("codeforge.state").maybe_complete(require("codeforge.state").change_for_path(%s))
	]],
		vim.inspect(path),
		vim.inspect(path)
	))
end

local function try_write()
	child.lua([[
		local ok, err = pcall(vim.cmd, "write")
		_G.__wok, _G.__werr = ok, tostring(err)
	]])
	return child.lua_get([[_G.__wok]]), child.lua_get([[_G.__werr]])
end
---True when the CodeForge save guard (BufWriteCmd) is attached to `buf`.
local function guard_attached(buf)
	return child.lua_get(string.format(
		[[#vim.api.nvim_get_autocmds({ event = "BufWriteCmd", group = "codeforge_save_guard", buffer = %d }) > 0]],
		buf
	))
end

T["a BufWritePre error aborts the write, leaves disk unchanged, and keeps options"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	child.fn.writefile({ "local a = 1", "local b = 2" }, path)
	local buf = Q.find_buf(path)

	child.lua(string.format(
		[[
			_G.__posts = 0
			vim.api.nvim_create_autocmd("BufWritePre", { buffer = %d, callback = function()
				error("probe formatter error")
			end })
			vim.api.nvim_create_autocmd("BufWritePost", { buffer = %d, callback = function()
				_G.__posts = _G.__posts + 1
			end })
		]],
		buf,
		buf
	))

	local ok, err = try_write()
	MiniTest.expect.equality(ok, false, { fail_reason = "a BufWritePre error must fail the write" })
	MiniTest.expect.equality(
		err:find("probe formatter error", 1, true) ~= nil,
		true,
		{ fail_reason = "the hook error must propagate, got: " .. tostring(err) }
	)
	MiniTest.expect.equality(child.fn.readfile(path), { "local a = 1", "local b = 2" }, {
		fail_reason = "disk must be unchanged after a failed BufWritePre",
	})
	MiniTest.expect.equality(child.lua_get([[_G.__posts]]), 0, {
		fail_reason = "BufWritePost must not fire when BufWritePre failed",
	})
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("buftype", { buf = buf }),
		"acwrite",
		{ fail_reason = "options must stay consistent (guard re-armed) after a failed write" }
	)
end

T["a BufWritePost error propagates and leaves the guard consistent"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	local buf = Q.find_buf(path)

	child.lua(string.format(
		[[vim.api.nvim_create_autocmd("BufWritePost", { buffer = %d, callback = function()
			error("probe post error")
		end })]],
		buf
	))

	local ok, err = try_write()
	MiniTest.expect.equality(ok, false, { fail_reason = "a BufWritePost error must fail the write" })
	MiniTest.expect.equality(
		err:find("probe post error", 1, true) ~= nil,
		true,
		{ fail_reason = "the post error must propagate, got: " .. tostring(err) }
	)
	-- the write itself happened
	MiniTest.expect.equality(child.fn.readfile(path), { "local a = 1", "local b = 20" })
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("buftype", { buf = buf }),
		"acwrite",
		{ fail_reason = "options must stay consistent after a post-hook error" }
	)
end

T["a failed save does not corrupt the guard for the next save"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	local buf = Q.find_buf(path)

	-- first save fails in BufWritePre
	local ac = child.lua_get(string.format(
		[[(function()
			local id = vim.api.nvim_create_autocmd("BufWritePre", { buffer = %d, callback = function()
				error("probe formatter error")
			end })
			return id
		end)()]],
		buf
	))
	local ok1, err1 = try_write()
	MiniTest.expect.equality(ok1, false, { fail_reason = "first save must fail; got " .. tostring(err1) })
	MiniTest.expect.equality(child.fn.readfile(path), { "local a = 1", "local b = 2" }, {
		fail_reason = "disk unchanged after the failed save",
	})

	-- remove the failing hook; the next save must still be allowed
	child.lua(string.format([[vim.api.nvim_del_autocmd(%d)]], ac))
	local ok2, err2 = try_write()
	MiniTest.expect.equality(ok2, true, {
		fail_reason = "a later save must succeed after a failed hook; got " .. tostring(err2),
	})
	MiniTest.expect.equality(child.fn.readfile(path), { "local a = 1", "local b = 20" })
end

T["normal save hooks run during a review and their edits reach disk"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	local buf = Q.find_buf(path)

	child.lua(string.format(
		[[
			_G.__hooks = {}
			vim.api.nvim_create_autocmd("BufWritePre", { buffer = %d, callback = function()
				table.insert(_G.__hooks, "pre")
				vim.api.nvim_buf_set_lines(%d, 0, 1, false, { "local a = 1 -- formatted" })
			end })
			vim.api.nvim_create_autocmd("BufWritePost", { buffer = %d, callback = function()
				table.insert(_G.__hooks, "post")
			end })
		]],
		buf,
		buf,
		buf
	))

	local ok, err = try_write()
	MiniTest.expect.equality(ok, true, { fail_reason = ":w should succeed; got " .. tostring(err) })
	MiniTest.expect.equality(
		child.lua_get([[_G.__hooks]]),
		{ "pre", "post" },
		{ fail_reason = "BufWritePre/BufWritePost must fire for a review save" }
	)
	-- the BufWritePre edit is what lands on disk
	MiniTest.expect.equality(child.fn.readfile(path)[1], "local a = 1 -- formatted")
end

T["a write error propagates instead of being swallowed"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	-- external divergence makes the guard refuse the write
	child.fn.writefile({ "external" }, path)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, false, { fail_reason = "the refused write must raise an error" })
	MiniTest.expect.equality(
		err:find("changed on disk", 1, true) ~= nil,
		true,
		{ fail_reason = "got: " .. tostring(err) }
	)
end

T["saving during an open review writes the accepted content"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, true, { fail_reason = ":w should succeed during review; got " .. tostring(err) })
	MiniTest.expect.equality(child.fn.readfile(path), { "local a = 1", "local b = 20" })
end

T["saving succeeds when integration wrote the same content to disk"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	-- simulate jj integration: disk now holds exactly the review buffer content
	child.lua(
		string.format(
			[[vim.fn.writefile(vim.api.nvim_buf_get_lines(vim.fn.bufnr(%s), 0, -1, false), %s)]],
			vim.inspect(path),
			vim.inspect(path)
		)
	)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, true, { fail_reason = ":w should succeed when disk == buffer; got " .. tostring(err) })
end

T["saving still warns when disk holds different content"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	child.fn.writefile({ "something else entirely" }, path)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, false, { fail_reason = "real disk divergence must refuse the write" })
	MiniTest.expect.equality(
		err:find("changed on disk", 1, true) ~= nil,
		true,
		{ fail_reason = "got: " .. tostring(err) }
	)
end

T["consecutive saves during an open review both succeed"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	local ok1, err1 = try_write()
	MiniTest.expect.equality(ok1, true, { fail_reason = "first :w should succeed; got " .. tostring(err1) })

	-- modify a line outside the proposed hunk, then save again
	child.api.nvim_buf_set_lines(Q.find_buf(path), 0, 1, false, { "local a = 1 -- x" })
	local ok2, err2 = try_write()
	MiniTest.expect.equality(ok2, true, { fail_reason = "second :w should succeed; got " .. tostring(err2) })

	MiniTest.expect.equality(child.fn.readfile(path)[1], "local a = 1 -- x")
end

T["a real external change during an open review still refuses the write"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	child.fn.writefile({ "external", "content" }, path)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, false, { fail_reason = "external divergence must refuse the write" })
	MiniTest.expect.equality(
		err:find("changed on disk", 1, true) ~= nil,
		true,
		{ fail_reason = "got: " .. tostring(err) }
	)
end

T["completion restores the buffer options and detaches the save guard"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)

	local buf = Q.find_buf(path)
	MiniTest.expect.equality(child.api.nvim_get_option_value("buftype", { buf = buf }), "acwrite", {
		fail_reason = "precondition: review hijacks buftype",
	})

	complete_review(path)

	MiniTest.expect.equality(child.api.nvim_get_option_value("buftype", { buf = buf }), "", {
		fail_reason = "buftype must be restored to normal after completion",
	})
	MiniTest.expect.equality(child.api.nvim_get_option_value("swapfile", { buf = buf }), true, {
		fail_reason = "swapfile must be restored after completion",
	})
	MiniTest.expect.equality(guard_attached(buf), false, {
		fail_reason = "the review save guard must be detached after completion",
	})
end

T["dismissal restores the buffer options and detaches the save guard"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	local buf = Q.find_buf(path)

	child.lua(string.format([[require("codeforge.review.buffer").dismiss(%s)]], vim.inspect(path)))

	MiniTest.expect.equality(
		child.api.nvim_get_option_value("buftype", { buf = buf }),
		"",
		{ fail_reason = "buftype must be restored after dismissal" }
	)
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("swapfile", { buf = buf }),
		true,
		{ fail_reason = "swapfile must be restored after dismissal" }
	)
	MiniTest.expect.equality(guard_attached(buf), false, {
		fail_reason = "the review save guard must be detached after dismissal",
	})
end

T["undo revival re-arms the save guard"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	complete_review(path)

	MiniTest.expect.equality(
		child.api.nvim_get_option_value("buftype", { buf = Q.find_buf(path) }),
		"",
		{ fail_reason = "precondition: guard detached on completion" }
	)

	child.lua_get([[require("codeforge.sidebar.actions").undo()]])

	MiniTest.expect.equality(
		child.lua_get(string.format([[require("codeforge.state").get_review(%s) ~= nil]], vim.inspect(path))),
		true,
		{ fail_reason = "the review should be revived" }
	)
	local buf = Q.find_buf(path)
	MiniTest.expect.equality(
		child.api.nvim_get_option_value("buftype", { buf = buf }),
		"acwrite",
		{ fail_reason = "revival must re-arm the review save guard" }
	)
end

return T
