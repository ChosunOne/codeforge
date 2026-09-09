do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

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
	]],
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

T["saving a completed review does not warn when disk is untouched"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	complete_review(path)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, true, { fail_reason = ":w should succeed; got " .. tostring(err) })
	MiniTest.expect.equality(child.fn.readfile(path), { "local a = 1", "local b = 20" })
end

T["saving succeeds when integration wrote the same content to disk"] = function()
	local path = F.tmp_path("_review_target.lua")
	review_real_file(path)
	complete_review(path)

	-- simulate jj integration: disk now holds exactly the accepted content
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
	complete_review(path)

	child.fn.writefile({ "something else entirely" }, path)

	local ok, err = try_write()
	MiniTest.expect.equality(ok, false, { fail_reason = "real disk divergence must refuse the write" })
	MiniTest.expect.equality(
		err:find("changed on disk", 1, true) ~= nil,
		true,
		{ fail_reason = "got: " .. tostring(err) }
	)
end

return T
