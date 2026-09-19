do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures")
F.set_child(child)

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			child.lua([[require("codeforge.state").reset(); require("codeforge.state").log_file = nil]])
		end,
		post_case = F.cleanup,
		post_once = child.stop,
	},
})

local function open_added(lines)
	local path = F.tmp_path()
	F.seed_added_file(path, lines)
	child.lua(string.format(
		[[
		_G.path = %s
		require("codeforge.review.buffer").open(path)
		_G.review = require("codeforge.state").get_review(path)
		_G.file = require("codeforge.state").changes[1].files[1]
	]],
		vim.inspect(path)
	))
	return path
end

T["accepting the new-file hunk updates its file row without completing pending siblings"] = function()
	open_added({ "new content", "second line" })
	local sibling = F.tmp_path()
	child.lua(string.format(
		[[
		local state = require("codeforge.state")
		table.insert(state.changes[1].files, {
			path = %s, status = "added", hunks = { {
				id = "sibling", old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+sibling" },
			} },
		})
		state.set_on_change(function() _G.decision_at_refresh = file.decision end)
	]],
		vim.inspect(sibling)
	))
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(child.lua_get([[file.decision]]), "accepted")
	MiniTest.expect.equality(child.lua_get([[_G.decision_at_refresh]]), "accepted")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").file_completed(file)]]), true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").file_status_glyph(file)]]), "●")
	MiniTest.expect.equality(
		child.lua_get([[require("codeforge.state").derive_status(require("codeforge.state").changes[1])]]),
		"pending"
	)
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").log]]), 0)

	-- Opposite bulk action must skip the already accepted file, not overwrite it.
	MiniTest.expect.equality(child.lua_get([[require("codeforge.sidebar.actions").reject_pending()]]), 1)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").log[1].files[1].decision]]), "accepted")
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").log[1].files[2].decision]]), "rejected")
	MiniTest.expect.equality(
		child.api.nvim_buf_get_lines(child.lua_get([[review.buf]]), 0, -1, false),
		{ "new content", "second line" }
	)
end

for _, case in ipairs({
	{ name = "accept", key = "<C-x>a", status = "accepted", final = { "proposal" } },
	{ name = "reject", key = "<C-x>j", status = "rejected", final = { "" } },
}) do
	T[case.name .. " of a new-file hunk completes and undo/redo restores both levels"] = function()
		local path = open_added({ "proposal" })
		local buf = child.lua_get([[review.buf]])
		child.type_keys(case.key)
		MiniTest.expect.equality(child.lua_get([[file.decision]]), case.status)
		MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
		MiniTest.expect.equality(child.lua_get([[require("codeforge.state").log[1].status]]), case.status)
		MiniTest.expect.equality(child.lua_get([[require("codeforge.state").log[1].files[1].decision]]), case.status)
		MiniTest.expect.equality(child.lua_get([[require("codeforge.state").get_review(path) == nil]]), true)
		MiniTest.expect.equality(child.api.nvim_buf_get_lines(buf, 0, -1, false), case.final)
		MiniTest.expect.equality(child.api.nvim_get_option_value("buftype", { buf = buf }), "")
		MiniTest.expect.equality(child.fn.filereadable(path), 0)

		child.lua([[require("codeforge.sidebar.actions").undo()]])
		MiniTest.expect.equality(child.lua_get([[file.decision]]), vim.NIL)
		MiniTest.expect.equality(child.lua_get([[review.hunk_status[review.hunks[1].id] == nil]]), true)
		MiniTest.expect.equality(child.lua_get([[require("codeforge.state").file_completed(file)]]), false)
		MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 1)
		MiniTest.expect.equality(child.api.nvim_buf_get_lines(buf, 0, -1, false), { "proposal" })

		child.lua([[require("codeforge.sidebar.actions").redo()]])
		MiniTest.expect.equality(child.lua_get([[file.decision]]), case.status)
		MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
		MiniTest.expect.equality(child.api.nvim_buf_get_lines(buf, 0, -1, false), case.final)
		MiniTest.expect.equality(child.fn.filereadable(path), 0)
	end
end

T["accepting a blank new-file hunk completes without creating a disk file"] = function()
	local path = open_added({ "" })
	child.type_keys("<C-x>a")
	MiniTest.expect.equality(child.lua_get([[file.decision]]), "accepted")
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
	MiniTest.expect.equality(child.fn.filereadable(path), 0)
end

T["file-level hunk sweep updates the decision and history restoration clears it"] = function()
	open_added({ "proposal" })
	child.lua([[review:accept_pending()]])
	MiniTest.expect.equality(child.lua_get([[file.decision]]), "accepted")
	child.lua([[
		review:apply_history_state(review.hunks[1].id, "conflicted",
			vim.api.nvim_buf_get_lines(review.buf, 0, -1, false), review:_snapshot_placements())
	]])
	MiniTest.expect.equality(child.lua_get([[file.decision]]), vim.NIL)
	MiniTest.expect.equality(child.lua_get([[require("codeforge.state").file_completed(file)]]), false)
end

T["accepting a new file preserves actual pre-review unsaved content"] = function()
	local path = F.tmp_path()
	child.cmd("edit " .. path)
	child.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved user content" })
	F.seed_added_file(path, { "proposal" })
	child.lua(string.format(
		[[
		require("codeforge.review.buffer").open(%s)
		_G.review = require("codeforge.state").get_review(%s)
		review:accept_hunk(0)
	]],
		vim.inspect(path),
		vim.inspect(path)
	))
	MiniTest.expect.equality(child.lua_get([[#require("codeforge.state").changes]]), 0)
	MiniTest.expect.equality(
		child.api.nvim_buf_get_lines(child.lua_get([[review.buf]]), 0, -1, false),
		{ "proposal", "unsaved user content" }
	)
	MiniTest.expect.equality(child.fn.filereadable(path), 0)
end

return T
