do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures") ---@type Fixtures
F.set_child(child)

---The sidebar buffer, found by filetype (never wins[#wins]).
local function sidebar_buf()
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_get_option_value("filetype", { buf = b }) == "codeforge" then
			return b
		end
	end
	return nil
end

---Load a real which-key in the child (from the host's plugin dir), so we test
---against the actual cache-regeneration contract rather than a mock. Skips the
---case when which-key is not installed: these tests verify codeforge's
---decoupled announcement against a real consumer, not a hard dependency.
local function load_whichkey()
	local ok = child.lua_get([[vim.fn.isdirectory(vim.fn.stdpath("data") .. "/lazy/which-key.nvim") == 1]])
	if not ok then
		MiniTest.skip("which-key.nvim is not installed")
	end
	child.lua([[vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/which-key.nvim")]])
	child.lua([[require("which-key").setup({})]])
	child.lua([[vim.api.nvim_exec_autocmds("VimEnter", {})]])
	child.lua([[vim.wait(150)]])
end

---Ask which-key's cache whether it can see `lhs` in `buf`, and whether it
---installed a trigger for the `<C-x>`/`o` prefix.
---@param buf integer
---@param lhs string
---@param trigger_prefix string?
local function wk_sees(buf, lhs, trigger_prefix)
	return child.lua_get(string.format(
		[=[(function()
			local Buf = require("which-key.buf")
			local m = Buf.bufs[%d] and Buf.bufs[%d].modes["n"]
			if not m then return { cached = false, sees = false, trigger = false } end
			local trig = false
			for _, t in ipairs(m.triggers or {}) do
				if t.keys == %s then trig = true end
			end
			return { cached = true, sees = m.tree:find(%s) ~= nil, trigger = trig }
		end)()]=],
		buf,
		buf,
		vim.inspect(trigger_prefix or "<C-X>"),
		vim.inspect(lhs)
	))
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

-- ── The bug: which-key cached the buffer before our maps existed ─────────

T["which-key sees review keymaps installed by open() on an already-cached file buffer"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	-- Open the file first so which-key caches a *mapping-less* snapshot of it.
	child.cmd("edit " .. path)
	load_whichkey()

	local buf = child.fn.bufnr(path)
	local before = wk_sees(buf, "<C-x>", "<C-X>")
	MiniTest.expect.equality(before.cached, true, {
		fail_reason = "precondition: which-key cached the pre-review file buffer",
	})
	MiniTest.expect.equality(before.sees, false, {
		fail_reason = "precondition: the cached snapshot must not already see <C-x>",
	})

	F.seed_change(path, O, { F.replace_hunk("hunk-001", 2, "b", "b", "B") })
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	child.lua([[vim.wait(150)]])

	local after = wk_sees(buf, "<C-x>", "<C-X>")
	MiniTest.expect.equality(after.sees, true, {
		fail_reason = "which-key must re-read the buffer and see <C-x> after open(), got " .. vim.inspect(after),
	})
	MiniTest.expect.equality(after.trigger, true, {
		fail_reason = "which-key must install a <C-x> trigger after open(), got " .. vim.inspect(after),
	})
end

T["which-key sees review keymaps on a never-opened file (bufload happens before maps)"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	load_whichkey()

	F.seed_change(path, O, { F.replace_hunk("hunk-001", 2, "b", "b", "B") })
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	child.lua([[vim.wait(150)]])

	local buf = child.fn.bufnr(path)
	local after = wk_sees(buf, "<C-x>", "<C-X>")
	MiniTest.expect.equality(after.cached, true, { fail_reason = "the review buffer should be cached" })
	MiniTest.expect.equality(after.sees, true, {
		fail_reason = "which-key must see <C-x> even when bufload raced our keymap install, got " .. vim.inspect(after),
	})
end

-- ── Removal must be announced too, or which-key keeps stale entries ──────

T["which-key drops review keymaps after dismiss"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	load_whichkey()

	F.seed_change(path, O, { F.replace_hunk("hunk-001", 2, "b", "b", "B") })
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	child.lua([[vim.wait(150)]])
	local buf = child.fn.bufnr(path)
	MiniTest.expect.equality(wk_sees(buf, "<C-x>", "<C-X>").sees, true, {
		fail_reason = "precondition: <C-x> visible during review",
	})

	child.lua(string.format([[require("codeforge.review.buffer").dismiss(%s)]], vim.inspect(path)))
	child.lua([[vim.wait(150)]])

	local after = wk_sees(buf, "<C-x>", "<C-X>")
	MiniTest.expect.equality(after.sees, false, {
		fail_reason = "which-key must not keep offering <C-x> after dismiss, got " .. vim.inspect(after),
	})
	MiniTest.expect.equality(after.trigger, false, {
		fail_reason = "which-key must drop the now-dangling <C-x> trigger after dismiss",
	})
end

-- ── The sidebar installs its maps during an async render ─────────────────

T["which-key sees sidebar keymaps installed by render"] = function()
	load_whichkey()
	child.lua([[
                local state = require("codeforge.state")
                state.changes = {
                        {
                                id = "change-001",
                                title = "Test",
                                files = {
                                        { path = "src/file.lua", status = "modified", hunks = {} },
                                },
                        },
                }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]])
	child.cmd("CodeForge")

	local sb
	for _ = 1, 40 do
		sb = sidebar_buf()
		if sb then
			break
		end
		child.lua([[vim.wait(25)]])
	end
	MiniTest.expect.equality(sb ~= nil, true, { fail_reason = "sidebar buffer not found" })

	-- The sidebar's maps are installed by its render; poll for which-key to
	-- have them rather than reading once (render is scheduled).
	local seen
	for _ = 1, 40 do
		seen = wk_sees(sb, "o", "o")
		if seen.sees then
			break
		end
		child.lua([[vim.wait(25)]])
	end
	MiniTest.expect.equality(seen.cached, true, {
		fail_reason = "which-key should have cached the sidebar buffer",
	})
	MiniTest.expect.equality(seen.sees, true, {
		fail_reason = "which-key must see the sidebar's `o` map after render, got " .. vim.inspect(seen),
	})
end

-- ── Evidence value: announce must not disturb a buffer with unsaved edits ─

T["announce leaves buffer contents, changedtick, and filetype untouched"] = function()
	local path = F.tmp_path()
	child.fn.writefile({ "a", "b", "c" }, path)
	child.cmd("edit " .. path)
	child.lua(
		string.format(
			[[vim.api.nvim_buf_set_lines(vim.fn.bufnr(%s), 0, -1, false, { "a", "UNSAVED" })]],
			vim.inspect(path)
		)
	)
	local buf = child.fn.bufnr(path)
	local before = child.lua_get(
		string.format(
			[[{ lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr(%s), 0, -1, false), tick = vim.api.nvim_buf_get_changedtick(vim.fn.bufnr(%s)), ft = vim.bo[vim.fn.bufnr(%s)].filetype }]],
			vim.inspect(path),
			vim.inspect(path),
			vim.inspect(path)
		)
	)

	child.lua(string.format([[require("codeforge.keymaps").announce(%d)]], buf))
	child.lua([[vim.wait(80)]])

	local after = child.lua_get(
		string.format(
			[[{ lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr(%s), 0, -1, false), tick = vim.api.nvim_buf_get_changedtick(vim.fn.bufnr(%s)), ft = vim.bo[vim.fn.bufnr(%s)].filetype }]],
			vim.inspect(path),
			vim.inspect(path),
			vim.inspect(path)
		)
	)
	MiniTest.expect.equality(vim.deep_equal(before, after), true, {
		fail_reason = "announce must be a pure cache signal; before="
			.. vim.inspect(before)
			.. " after="
			.. vim.inspect(after),
	})
end

T["announce is a no-op for an invalid buffer"] = function()
	local ok = child.lua_get([[pcall(require("codeforge.keymaps").announce, 99999)]])
	MiniTest.expect.equality(ok, true, { fail_reason = "announce must tolerate an invalid buffer" })
	local ok_nil = child.lua_get([[pcall(require("codeforge.keymaps").announce, nil)]])
	MiniTest.expect.equality(ok_nil, true, { fail_reason = "announce must tolerate nil" })
end

return T
