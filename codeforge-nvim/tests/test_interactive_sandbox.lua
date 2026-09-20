do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

-- The interactive sandbox is included more than once in one Neovim process: by
-- hand with :luafile, and by tests that dofile() it. Its fixture creates a
-- buffer with a fixed name, which used to collide on the second include
-- (Vim:E95: Buffer with this name already exists) and abort whatever test was
-- mid-flight. These tests pin that it re-seeds cleanly instead.
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
		end,
		post_once = child.stop,
	},
})

local function include()
	return child.lua_get([[{ pcall(dofile, "tests/interactive.lua") }]])
end

T["including the sandbox twice in one process succeeds"] = function()
	local first = include()
	MiniTest.expect.equality(first[1], true, { fail_reason = "first include failed: " .. tostring(first[2]) })
	local second = include()
	MiniTest.expect.equality(second[1], true, {
		fail_reason = "second include must not collide: " .. tostring(second[2]),
	})
end

T["re-including reuses the one named buffer rather than duplicating it"] = function()
	include()
	local before = child.lua_get([[vim.fn.bufnr("src/net/service.lua")]])
	include()
	local after = child.lua_get([[vim.fn.bufnr("src/net/service.lua")]])
	MiniTest.expect.equality(after, before, { fail_reason = "the sandbox buffer must be reused" })

	-- Exactly one buffer in the process may carry that name.
	local count = child.lua_get([[
			(function()
				local n = 0
				local want = vim.fn.fnamemodify("src/net/service.lua", ":p")
				for _, b in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_valid(b)
						and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p") == want
					then
						n = n + 1
					end
				end
				return n
			end)()
		]])
	MiniTest.expect.equality(count, 1)
end

T["re-including leaves a usable review, not a stale one"] = function()
	include()
	include()
	-- The second include must install a fresh review for the re-seeded buffer:
	-- a stale one would still point at the previous review's placements.
	local info = child.lua_get([[
		(function()
			local state = require("codeforge.state")
			local review = state.get_review("src/net/service.lua")
			return {
				registered = review ~= nil,
				buf = review and review.buf or -1,
				named = vim.fn.bufnr("src/net/service.lua"),
				statuses = review and review.hunk_status or {},
				hunks = review and #review.placements or 0,
			}
		end)()
	]])
	MiniTest.expect.equality(info.registered, true)
	MiniTest.expect.equality(info.buf, info.named, { fail_reason = "review must own the named buffer" })
	MiniTest.expect.equality(info.hunks > 0, true)
	-- The sandbox seeds two conflicted hunks so you can jump to the resolve flow.
	MiniTest.expect.equality(info.statuses["hunk-default-host"], "conflicted")
	MiniTest.expect.equality(info.statuses["hunk-retry-connect"], "conflicted")
end

T["re-including leaves no stale save guard on the sandbox buffer"] = function()
	include()
	include()
	-- The sandbox buffer is a scratch buffer, so no save guard is attached at
	-- all; what matters is that a re-include never leaves one behind pointing
	-- at a discarded review.
	local guard =
		child.lua_get([[require("codeforge.review.buffer").save_guards[vim.fn.bufnr("src/net/service.lua")] ~= nil]])
	MiniTest.expect.equality(guard, false, { fail_reason = "a discarded review must not keep owning saving" })
	-- Releasing the guard must not have corrupted the scratch buffer's type.
	MiniTest.expect.equality(child.lua_get([[vim.bo[vim.fn.bufnr("src/net/service.lua")].buftype]]), "nofile")
end

T["the sandbox change set is replaced, not accumulated"] = function()
	include()
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
	include()
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1, {
		fail_reason = "re-including must re-seed the one sandbox change, not append",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].id]]), "change-sandbox")
end

return T
