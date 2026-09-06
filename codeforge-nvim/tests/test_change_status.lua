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

---Seed a change whose single file has hunks with the given review statuses.
---statuses is an ordered list parallel to the two hunks h1 (replace b) and
---h2 (replace d). Entries: "accepted"|"rejected"|nil (pending).
---@param statuses (string|nil)[]
---@param user_modified? boolean simulate a hand-edit on the review
local function seed_with_statuses(statuses, user_modified)
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.lua(string.format(
		[[
                local state = require("codeforge.state")
                local statuses = %s
                local user_modified = %s
                local review = {
                        path = %s,
                        hunk_status = {},
                        user_modified = user_modified,
                }
                local change = state.changes[1]
                for i, h in ipairs(change.files[1].hunks) do
                        if statuses[i] ~= nil then
                                review.hunk_status[h.id] = statuses[i]
                        end
                end
                -- only register a review if any hunk was triaged or it was edited
                if user_modified or statuses[1] ~= nil or statuses[2] ~= nil then
                        state.reviews[%s] = review
                end
        ]],
		vim.inspect(statuses),
		tostring(user_modified and true or false),
		vim.inspect(path),
		vim.inspect(path)
	))
end

---derive_status of the single seeded change.
local function derive()
	return child.lua_get([[require("codeforge.state").derive_status(require("codeforge.state").changes[1])]])
end

T["derive_status: all hunks pending -> pending"] = function()
	seed_with_statuses({ nil, nil })
	MiniTest.expect.equality(derive(), "pending")
end

T["derive_status: one accepted, one pending -> pending"] = function()
	seed_with_statuses({ "accepted", nil })
	MiniTest.expect.equality(derive(), "pending")
end

T["derive_status: all accepted, no edits -> accepted"] = function()
	seed_with_statuses({ "accepted", "accepted" })
	MiniTest.expect.equality(derive(), "accepted")
end

T["derive_status: all rejected, no edits -> rejected"] = function()
	seed_with_statuses({ "rejected", "rejected" })
	MiniTest.expect.equality(derive(), "rejected")
end

T["derive_status: mixed accepted+rejected -> modified"] = function()
	seed_with_statuses({ "accepted", "rejected" })
	MiniTest.expect.equality(derive(), "modified")
end

T["derive_status: all accepted but user hand-edited proposal -> modified"] = function()
	seed_with_statuses({ "accepted", "accepted" }, true)
	MiniTest.expect.equality(derive(), "modified")
end

---Seed a change with one added and one deleted file (both atomic).
local function seed_atomic()
	child.lua([[
                    local state = require("codeforge.state")
                    state.reset()
                    state.changes = {
                            {
                                    id = "change-001",
                                    title = "Atomic",
                                    files = {
                                            { path = "src/new.lua", status = "added", hunks = {} },
                                            { path = "src/old.lua", status = "deleted", hunks = {} },
                                    }
                            }
                    }
                    state.current_change_index = 1
                    state.current_change_id = "change-001"
            ]])
end

T["derive_status: undecided atomic files gate the change at pending"] = function()
	seed_atomic()
	MiniTest.expect.equality(derive(), "pending")
end

T["derive_status: decided added + undecided deleted -> pending"] = function()
	seed_atomic()
	child.lua([[require("codeforge.state").changes[1].files[1].decision = "accepted"]])
	MiniTest.expect.equality(derive(), "pending")
end

T["derive_status: both atomic files accepted -> accepted"] = function()
	seed_atomic()
	child.lua([[require("codeforge.state").changes[1].files[1].decision =  "accepted"]])
	child.lua([[require("codeforge.state").changes[1].files[2].decision = "accepted"]])
	MiniTest.expect.equality(derive(), "accepted")
end

T["derive_status: added accepted + deleted rejected -> modified"] = function()
	seed_atomic()
	child.lua([[require("codeforge.state").changes[1].files[1].decision = "accepted"]])
	child.lua([[require("codeforge.state").changes[1].files[2].decision = "rejected"]])
	MiniTest.expect.equality(derive(), "modified")
end

local function open_review(path)
	child.lua(string.format([[require("codeforge.review.buffer").open(%s)]], vim.inspect(path)))
	return Q.find_buf(path)
end

local function derive_live()
	return child.lua_get([[require("codeforge.state").derive_status(require("codeforge.state").changes[1])]])
end

---Poll derive_status until it equals `want` or ~1.5s elapse (absorbs the
---edit reconciler's debounce and async accept). Returns the last seen value.
local function await_status(want)
	local v = derive_live()
	for _ = 1, 30 do
		if v == want then
			return v
		end
		vim.loop.sleep(50)
		v = derive_live()
	end
	return v
end

T["derive_status: accepting every hunk via <C-x>a yields accepted"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	MiniTest.expect.equality(derive_live(), "pending")

	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(derive_live(), "pending")

	child.api.nvim_win_set_cursor(win, { 4, 0 })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(derive_live(), "accepted")
end

T["derive_status: accepting one, rejecting the other yields modified"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)
	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	child.api.nvim_win_set_cursor(win, { 4, 0 })
	child.type_keys("<C-x>j")

	MiniTest.expect.equality(derive_live(), "modified")
end

T["derive_status: hand-editing the proposal then accepting all yields modified"] = function()
	local O = { "a", "b", "c" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	F.seed_change(path, O, { h1 })

	local buf = open_review(path)
	Q.expect_lines("P", child.api.nvim_buf_get_lines(buf, 0, -1, false), { "a", "B", "c" })

	child.api.nvim_set_current_win(Q.win_for_buf(buf))
	child.api.nvim_win_set_cursor(0, { 2, 0 })
	child.type_keys("A-edited<esc>")
	child.api.nvim_win_set_cursor(0, { 2, 0 })
	child.type_keys("<C-x>a")

	MiniTest.expect.equality(await_status("modified"), "modified")
end

local function sidebar_buf()
	for _, w in ipairs(child.api.nvim_list_wins()) do
		local b = child.api.nvim_win_get_buf(w)
		if child.api.nvim_get_option_value("filetype", { buf = b }) == "codeforge" then
			return b
		end
	end
	return nil
end

---Poll up to ~1.5s for the sidebar status line (line 2) to contain `substr`.
local function await_status_line(substr)
	for _ = 1, 30 do
		local sb = sidebar_buf()
		if sb then
			local l2 = child.api.nvim_buf_get_lines(sb, 1, 2, false)[1] or ""
			if l2:find(substr, 1, true) then
				return l2
			end
		end
		child.lua([[vim.wait(50)]])
	end
	local sb = sidebar_buf()
	return sb and (child.api.nvim_buf_get_lines(sb, 1, 2, false)[1] or "") or ""
end

T["sidebar status line shows pending, then the derived status after triage"] = function()
	local O = { "a", "b", "c", "d" }
	local path = F.tmp_path()
	child.fn.writefile(O, path)
	child.cmd("edit " .. path)
	local h1 = F.replace_hunk("h1", 2, "b", "B")
	local h2 = F.replace_hunk("h2", 4, "d", "D")
	F.seed_change(path, O, { h1, h2 })

	child.cmd("CodeForge")
	local pending_line = await_status_line("pending")
	MiniTest.expect.equality(
		pending_line:find("pending", 1, true) ~= nil,
		true,
		{ fail_reason = "status line should show pending before any triage" }
	)
	MiniTest.expect.equality(
		pending_line:find("○", 1, true) ~= nil,
		true,
		{ fail_reason = "status line should lead with the ○ icon, got: " .. pending_line }
	)

	local buf = open_review(path)
	local win = Q.win_for_buf(buf)
	child.api.nvim_set_current_win(win)

	child.api.nvim_win_set_cursor(win, { 2, 0 })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(
		await_status_line("pending"):find("pending", 1, true) ~= nil,
		true,
		{ fail_reason = "status line should stay pending while h2 is pending" }
	)

	child.api.nvim_win_set_cursor(win, { 4, 0 })
	child.type_keys("<C-x>j")
	local status_line = await_status_line("modified")
	MiniTest.expect.equality(
		status_line:find("modified", 1, true) ~= nil,
		true,
		{ fail_reason = "status line should show modified after mixed triage, got: " .. status_line }
	)
	MiniTest.expect.equality(
		status_line:find("◐", 1, true) ~= nil,
		true,
		{ fail_reason = "status line should lead with the ◐ icon, got: " .. status_line }
	)
end

return T
