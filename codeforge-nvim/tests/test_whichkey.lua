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
---case when which-key is not installed: the integration is optional.
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

---Check the cached tree AND the actual installed trigger. A cached trigger
---candidate alone does not mean that pressing the prefix will open a popup.
---@param buf integer
---@param lhs string
---@param trigger_prefix string?
local function wk_sees(buf, lhs, trigger_prefix)
	return child.lua_get(string.format(
		[=[(function()
			local Buf = require("which-key.buf")
			local m = Buf.bufs[%d] and Buf.bufs[%d].modes["n"]
			local trig = false
			for _, t in ipairs(vim.api.nvim_buf_get_keymap(%d, "n")) do
				if t.lhs == %s and t.desc == "which-key-trigger" then trig = true end
			end
			return { cached = m ~= nil, sees = m ~= nil and m.tree:find(%s) ~= nil, trigger = trig }
		end)()]=],
		buf,
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

T["opening a review does not leave a stale which-key mode queued"] = function()
	local path = F.tmp_path()
	child.fn.writefile({ "a", "b", "c" }, path)
	child.cmd("edit " .. path)
	load_whichkey()
	F.seed_change(path, { "a", "b", "c" }, { F.replace_hunk("h1", 2, "b", "B") })

	-- Queue an update before installing review mappings, in the same tick.
	-- Clearing the Mode here strands a stale job that can remove the new
	-- Ctrl-x trigger, depending on which job runs last.
	local stale = child.lua_get(string.format(
		[[(function()
		local Buf = require("which-key.buf")
		local Triggers = require("which-key.triggers")
		local buf = vim.fn.bufnr(%s)
		Buf.get({ buf = buf, mode = "n", update = true })
		require("codeforge.review.buffer").open(%s)
		local count = 0
		for mode in pairs(Triggers.suspended) do
			if mode.buf.buf == buf and Buf.bufs[buf].modes[mode.mode] ~= mode then
				count = count + 1
			end
		end
		return count
	end)()]],
		vim.inspect(path),
		vim.inspect(path)
	))
	MiniTest.expect.equality(stale, 0)
	child.lua([[vim.wait(150)]])
	MiniTest.expect.equality(wk_sees(child.fn.bufnr(path), "<C-x>n").trigger, true)

	child.api.nvim_win_set_cursor(0, { 1, 0 })
	child.type_keys(100, "<C-x>", "n")
	MiniTest.expect.equality(child.api.nvim_win_get_cursor(0)[1], 2)
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

T["announce does not replay file-load hooks or lazy-load which-key"] = function()
	child.lua([[
		_G.read_events = 0
		vim.api.nvim_create_autocmd("BufReadPost", {
			callback = function() _G.read_events = _G.read_events + 1 end,
		})
		require("codeforge.keymaps").announce(vim.api.nvim_get_current_buf())
	]])
	MiniTest.expect.equality(child.lua_get("_G.read_events"), 0)
	MiniTest.expect.equality(child.lua_get([[package.loaded["which-key"] == nil]]), true)
end

T["announce is a no-op for an invalid buffer"] = function()
	local ok = child.lua_get([[pcall(require("codeforge.keymaps").announce, 99999)]])
	MiniTest.expect.equality(ok, true, { fail_reason = "announce must tolerate an invalid buffer" })
	local ok_nil = child.lua_get([[pcall(require("codeforge.keymaps").announce, nil)]])
	MiniTest.expect.equality(ok_nil, true, { fail_reason = "announce must tolerate nil" })
end

return T
