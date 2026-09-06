local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.o.lines, child.o.columns = 20, 120
			child.lua([[require("codeforge.state").reset()]])
		end,
		post_once = child.stop,
	},
})

T["sidebar displays files in change"] = function()
	child.lua([[
                local state = require("codeforge.state")
                state.changes = {
                        {
                                id = "change-001",
                                title = "Add authentication system",
                                files = {
                                        { path = "src/auth.lua", status = "modified", hunks = {
                                                { id = "h1", description = "h1", status = "modified", new_start = 1 },
                                        } },
                                        { path = "src/middleware.lua", status = "added", hunks = {} },
                                        { path = "tests/auth_test.lua", status = "added", hunks = {} },
                                        { path = "src/old_auth.lua", status = "deleted", hunks = {} }
                                }
                        }
                }

                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]])

	child.cmd("CodeForge")

	local buf
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_get_option_value("filetype", { buf = b }) == "codeforge" then
			buf = b
			break
		end
	end
	MiniTest.expect.equality(buf ~= nil, true, { fail_reason = "sidebar buffer not found" })
	local lines = {}
	for _ = 1, 60 do
		lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)
		if #lines >= 7 and lines[1] and lines[1]:find("%[1/1%]") then
			break
		end
		child.lua([[vim.wait(25)]])
	end

	MiniTest.expect.equality(string.find(lines[1], "%[1/1%] Add authentication system") ~= nil, true, {
		fail_reason = "Got " .. lines[1],
	})

	MiniTest.expect.equality(string.find(lines[2], "^○ pending$") ~= nil, true, {
		fail_reason = "status line should be the icon + word, got " .. lines[2],
	})

	MiniTest.expect.equality(string.find(lines[3], "^○ ▸ src/auth.lua %[M%]") ~= nil, true, {
		fail_reason = "Got " .. lines[3],
	})

	MiniTest.expect.equality(string.find(lines[4], "^○   src/middleware.lua %[A%]$") ~= nil, true, {
		fail_reason = "Got " .. lines[4],
	})

	MiniTest.expect.equality(lines[4]:find("▸", 1, true) == nil and lines[4]:find("▾", 1, true) == nil, true, {
		fail_reason = "added file rows must not have an expand arrow, got " .. lines[4],
	})

	MiniTest.expect.equality(
		string.find(lines[5], "^○   tests/auth_test.lua %[A%]$") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[5] }
	)
	MiniTest.expect.equality(lines[5]:find("▸", 1, true) == nil and lines[5]:find("▾", 1, true) == nil, true, {
		fail_reason = "added file rows must not have an expand arrow, got " .. lines[5],
	})

	MiniTest.expect.equality(
		string.find(lines[6], "^○   src/old_auth.lua %[D%]$") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[6] }
	)

	MiniTest.expect.equality(lines[6]:find("▸", 1, true) == nil and lines[6]:find("▾", 1, true) == nil, true, {
		fail_reason = "deleted file rows must not have an expand arrow, got " .. lines[6],
	})

	MiniTest.expect.equality(#lines, 7, { fail_reason = "Should have exactly 7 lines" })
	MiniTest.expect.reference_screenshot(child.get_screenshot())
end

T["expanding a modified file should display hunks"] = function()
	child.lua([[
                local state = require("codeforge.state")
                state.changes = {
                        {
                                id = "change-001",
                                title = "Test",
                                files = {
                                        {
                                                path = "src/file.lua",
                                                status = "modified",
                                                hunks = {
                                                        {
                                                                id = "hunk-001",
                                                                description = "Add login function",
                                                                new_start = 0,
                                                                status = "modified"
                                                        }
                                                }
                                        }
                                }
                        }
                }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]])

	child.cmd("CodeForge")

	child.type_keys("3gg")

	child.type_keys("o")

	MiniTest.expect.reference_screenshot(child.get_screenshot())

	local wins = child.api.nvim_list_wins()
	local sidebar_win = wins[#wins]
	local buf = child.api.nvim_win_get_buf(sidebar_win)
	local lines = child.api.nvim_buf_get_lines(buf, 0, -1, false)

	MiniTest.expect.equality(
		string.find(lines[3], "^○ ▾ src/file.lua %[M%]") ~= nil,
		true,
		{ fail_reason = "Got " .. lines[3] }
	)

	MiniTest.expect.equality(
		string.find(lines[4], "Add login function") ~= nil,
		true,
		{ fail_reason = "Got " .. (lines[4] or nil) }
	)
end

local function seed_atomic_change()
	child.lua([[
                local state = require("codeforge.state")
                state.reset()
                state.changes = {
                        {
                                id = "change-001",
                                title = "Atomic files",
                                files = {
                                        { path = "src/legacy/gone.lua", status = "deleted", hunks = {} },
                                        { path = "src/new_module.lua", status = "added", hunks = {
                                                { id = "h1", description = "h1", status = "modified", new_start = 1 },
                                        } },
                                }
                        }
                }
                state.current_change_index = 1
                state.current_change_id = "change-001"
        ]])
end

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

T["pressing o on a deleted file toggles its decision between accepted and rejected"] = function()
	seed_atomic_change()
	child.cmd("CodeForge")

	MiniTest.expect.equality(await_line(3, "src/legacy/gone.lua"):find("^○", 1, false) ~= nil, true, {
		fail_reason = "deleted file should start undecided (○)",
	})

	child.type_keys("3gg")
	child.type_keys("o")
	local accepted_row = await_line(3, "●")
	MiniTest.expect.equality(accepted_row:find("●", 1, true) == 1, true, {
		fail_reason = "deleted file should show ● after first toggle, got " .. accepted_row,
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]), "accepted")

	child.type_keys("o")
	await_line(3, "●")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]), "rejected")

	child.type_keys("o")
	await_line(3, "●")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].files[1].decision]]), "accepted")
end

T["pressing o on an added file toggles its decision; the glyph color matches"] = function()
	seed_atomic_change()
	child.cmd("CodeForge")

	MiniTest.expect.equality(await_line(4, "src/new_module.lua"):find("^○", 1, false) ~= nil, true, {
		fail_reason = "added file should start undecided (○)",
	})

	child.type_keys("4gg")
	child.type_keys("o")
	local row = await_line(4, "●")
	MiniTest.expect.equality(row:find("●", 1, true) == 1, true, {
		fail_reason = "added file should show ● after toggle, got " .. row,
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").changes[1].files[2].decision]]), "accepted")
end

T["pressing <CR> on a deleted file does not open a review buffer"] = function()
	seed_atomic_change()
	child.cmd("CodeForge")
	await_line(3, "src/legacy/gone.lua")

	local before = #child.api.nvim_list_bufs()
	child.type_keys("3gg")
	child.type_keys("<CR>")
	child.lua([[vim.wait(200)]])

	MiniTest.expect.equality(#child.api.nvim_list_bufs(), before, {
		fail_reason = "no new buffer should be created for a deleted file",
	})
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").reviews["src/legacy/gone.lua"] == nil]]),
		true,
		{ fail_reason = "no review should start for a deleted file" }
	)
end

return T
