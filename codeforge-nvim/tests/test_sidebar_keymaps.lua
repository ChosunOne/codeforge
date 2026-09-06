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

---Poll until sidebar line `n` contains `substr` (async render).
local function await_line(n, substr)
	for _ = 1, 40 do
		local sb = sidebar_buf()
		if sb then
			local l = child.api.nvim_buf_get_lines(sb, n - 1, n, false)[1] or ""
			if l:find(substr, 1, true) then
				return l
			end
		end
		child.lua([[vim.wait(25)]])
	end
	local sb = sidebar_buf()
	return sb and (child.api.nvim_buf_get_lines(sb, n - 1, n, false)[1] or "") or ""
end

local function seed_change()
	child.lua([[
                local state = require("codeforge.state")
                state.reset()
                state.changes = {
                        {
                                id = "change-001",
                                title = "Test",
                                files = {
                                        {
                                                path = "src/file.lua",
                                                status = "modified",
                                                hunks = {
                                                        { id = "hunk-001", description = "Add login", status = "modified", new_start = 1 },
                                                },
                                        },
                                        { path = "src/legacy/gone.lua", status = "deleted", hunks = {} },
                                },
                        },
                }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]])
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
		end,
		post_once = child.stop,
	},
})

T["configured toggle_file key on a file row toggles expansion via actions.toggle_file"] = function()
	seed_change()
	child.cmd("CodeForge")
	await_line(3, "src/file.lua")

	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").is_expanded("src/file.lua")]]),
		false,
		{ fail_reason = "file should start collapsed" }
	)

	child.type_keys("3gg")
	child.type_keys("o")

	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").is_expanded("src/file.lua")]]),
		true,
		{ fail_reason = "toggle_file key should expand the file via the actions layer" }
	)
	MiniTest.expect.equality(
		await_line(3, "▾"):find("▾", 1, true) ~= nil,
		true,
		{ fail_reason = "row 3 should show the expanded indicator" }
	)

	child.type_keys("o")
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").is_expanded("src/file.lua")]]),
		false,
		{ fail_reason = "toggle_file key should collapse the file again" }
	)
end

T["<CR> on a row with no openable file is a no-op, not a dap-ui expand"] = function()
	seed_change()
	child.cmd("CodeForge")
	await_line(4, "src/legacy/gone.lua")

	local bufs_before = #child.api.nvim_list_bufs()
	child.type_keys("4gg")
	child.type_keys("<CR>")
	child.lua([[vim.wait(200)]])

	MiniTest.expect.equality(#child.api.nvim_list_bufs(), bufs_before, {
		fail_reason = "<CR> on a deleted file must not open anything (no leaked dap-ui expand mapping)",
	})
end

T["sidebar buffer-local normal-mode maps are exactly our configured keys"] = function()
	seed_change()
	child.cmd("CodeForge")
	local sb = sidebar_buf()
	MiniTest.expect.equality(sb ~= nil, true, { fail_reason = "sidebar buffer not found" })
	await_line(3, "src/file.lua")

	local maps = child.api.nvim_buf_get_keymap(sb, "n")
	local lhs = {}
	for _, m in ipairs(maps) do
		lhs[m.lhs] = true
	end
	local expected =
		{ ["<CR>"] = true, ["<C-[>"] = true, ["<C-]>"] = true, ["<C-X>A"] = true, ["<C-X>J"] = true, ["o"] = true }
	local missing, extra = {}, {}
	for k in pairs(expected) do
		if not lhs[k] then
			missing[#missing + 1] = k
		end
	end
	for k in pairs(lhs) do
		if not expected[k] then
			extra[#extra + 1] = k
		end
	end
	MiniTest.expect.equality(#missing == 0 and #extra == 0, true, {
		fail_reason = "buffer maps should be nav + toggle/open + change-scoped sweeps; missing=" .. vim.inspect(
			missing
		) .. " extra=" .. vim.inspect(extra),
	})
end

T["keybinds come from config.keymaps, not hardcoded dap-ui actions"] = function()
	-- Remap toggle_file to `t` and ensure `o` no longer toggles.
	child.lua([[require("codeforge").config.keymaps.toggle_file = "t"]])
	seed_change()
	child.cmd("CodeForge")
	await_line(3, "src/file.lua")
	-- ensure focus is the sidebar before typing
	child.lua(
		[[for _,w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_get_option_value('filetype', { buf = vim.api.nvim_win_get_buf(w)})=='codeforge' then vim.api.nvim_set_current_win(w) end end]]
	)

	child.type_keys("3gg")
	-- o is no longer bound to anything codeforge; it falls through to Vim's
	-- default open-line which errors on the readonly sidebar buffer. Guard it.
	child.lua([[vim.v.errmsg = ""]])
	pcall(function()
		child.type_keys("o")
	end)
	child.lua([[vim.wait(100)]])
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").is_expanded("src/file.lua")]]),
		false,
		{ fail_reason = "remapped away: default o must not toggle when config.keymaps.toggle_file is 't'" }
	)

	-- sanity: the live buffer actually maps t and not o
	local sb = sidebar_buf()
	local lhs = {}
	for _, m in ipairs(child.api.nvim_buf_get_keymap(sb, "n")) do
		lhs[#lhs + 1] = m.lhs
	end
	MiniTest.expect.equality(
		vim.tbl_contains(lhs, "t") and not vim.tbl_contains(lhs, "o"),
		true,
		{ fail_reason = "buffer should map t (not o), got " .. vim.inspect(lhs) }
	)

	child.type_keys("t")
	child.lua([[vim.wait(200)]])
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").is_expanded("src/file.lua")]]),
		true,
		{ fail_reason = "configured key t should toggle expansion" }
	)
	-- restore for other tests
	child.lua([[require("codeforge").config.keymaps.toggle_file = "o"]])
end

T["<C-x>A accepts pending hunks change-wide; triaged hunks survive <C-x>J"] = function()
	local O = { "a1", "a2", "a3" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "Sweep",
                        files = { {
                                path = %s,
                                status = "modified",
                                base = %s,
                                hunks = { {
                                        id = "h1",
                                        old_start = 2,
                                        old_lines = 1,
                                        new_start = 2,
                                        new_lines = 1,
                                        lines = { "-a2", "+A2" },
                                        status = "modified",
                                } },
                        } },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		vim.inspect(path),
		vim.inspect(O)
	))
	child.cmd("CodeForge")
	await_line(3, vim.fn.fnamemodify(path, ":t"))

	child.type_keys("<C-x>A")
	child.lua([[vim.wait(200)]])

	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[=[((require("codeforge.state").get_review(%s) or {}).hunk_status or {}).h1]=],
				vim.inspect(path)
			)
		),
		"accepted",
		{ fail_reason = "<C-x>A should accept the pending hunk change-wide" }
	)

	-- <C-x>J must not clobber the already-triaged hunk
	child.type_keys("<C-x>J")
	child.lua([[vim.wait(200)]])
	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[=[((require("codeforge.state").get_review(%s) or {}).hunk_status or {}).h1]=],
				vim.inspect(path)
			)
		),
		"accepted",
		{ fail_reason = "<C-x>J sweeps pending hunks only; triaged hunk must stay accepted" }
	)
end

T["<C-x>J rejects pending hunks change-wide"] = function()
	local O = { "a1", "a2" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                state.reset()
                state.changes = { {
                        id = "change-001",
                        title = "Sweep",
                        files = { {
                                path = %s,
                                status = "modified",
                                base = %s,
                                hunks = { {
                                        id = "h1",
                                        old_start = 1,
                                        old_lines = 1,
                                        new_start = 1,
                                        new_lines = 1,
                                        lines = { "-a1", "+A1" },
                                        status = "modified",
                                } },
                        } },
                } }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]],
		vim.inspect(path),
		vim.inspect(O)
	))
	child.cmd("CodeForge")
	await_line(3, vim.fn.fnamemodify(path, ":t"))

	child.type_keys("<C-x>J")
	child.lua([[vim.wait(200)]])

	MiniTest.expect.equality(
		child.lua_get(
			string.format(
				[=[((require("codeforge.state").get_review(%s) or {}).hunk_status or {}).h1]=],
				vim.inspect(path)
			)
		),
		"rejected",
		{ fail_reason = "<C-x>J should reject the pending hunk change-wide" }
	)
end

return T
