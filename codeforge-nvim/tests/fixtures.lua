---@class SeedFile
---@field path string
---@field status "added"|"modified"|"deleted"
---@field base string[]
---@field hunks Hunk[]

---@class Fixtures
local M = {}
local child ---@type MiniTest.child
local temp_files = {} ---@type string[]

---Bind this fixtures module to a mini.test child
---@param c MiniTest.child
function M.set_child(c)
	child = c
end

---Register a temporary path; removed on cleanup().
---Created in the host's $TMPDIR (child.fn.tempname).
---@param suffix? string optional filename suffix (default ".lua")
---@return string path
function M.tmp_path(suffix)
	local path = child.fn.tempname() .. (suffix or ".lua")
	temp_files[#temp_files + 1] = path
	return path
end

--- Remove every temp file created via tmp_path().
function M.cleanup()
	for _, p in ipairs(temp_files) do
		os.remove(p)
	end
	temp_files = {}
end

---Seed state.changes with a one-file change for `path`.
---@param path string
---@param O string[]
---@param hunks Hunk[]
function M.seed_change(path, O, hunks)
	child.lua(string.format(
		[[
	local state = require("codeforge.state")
	state.reset()
	state.changes = {
		{
			id = "change-001",
			title = "Test change",
			files = {
				{
					path = %s,
					status = "modified",
					base = %s,
					hunks = %s,
				},
			},
		},
	}
	state.current_change_index = 1
	state.current_change_id = "change-001"
	]],
		vim.inspect(path),
		vim.inspect(O),
		vim.inspect(hunks)
	))
end

---Seed state.changes with a one-file change for a newly added file at `path`
---`lines` is the file's full new content; it is rendered as a
---single pure-insertion hunk
---@param path string
---@param lines string[]
function M.seed_added_file(path, lines)
	local plus = {}
	for i, l in ipairs(lines) do
		plus[i] = "+" .. l
	end
	local hunk = {
		id = "hunk-add-file",
		old_start = 1,
		old_lines = 0,
		new_start = 1,
		new_lines = #lines,
		lines = plus,
	}

	child.lua(string.format(
		[[
		local state = require("codeforge.state")
		state.reset()
		state.changes = {
			{
				id = "change-001",
				title = "Test change",
				files = {
					{
						path = %s,
						status = "added",
						hunks = %s,
					}
				}
			}
		}
		state.current_change_index = 1
		state.current_change_id = "change-001"
	]],
		vim.inspect(path),
		vim.inspect({ hunk })
	))
end

---Replace line `old` (at `at`) with `new1` (and optionally `new2`).
---@param id string
---@param at number
---@param old string
---@param new1 string
---@param new2? string
---@return Hunk
function M.replace_hunk(id, at, old, new1, new2)
	return {
		id = id,
		old_start = at,
		old_lines = 1,
		new_start = at,
		new_lines = new2 and 2 or 1,
		lines = new2 and { "-" .. old, "+" .. new1, "+" .. new2 } or { "-" .. old, "+" .. new1 },
	}
end

---Insert `new_lines` before line `at` (no removal).
---@param id string
---@param at number 1-indexed line in the base O
---@param lines_removed string[] the exact base lines to remove
---@return Hunk
function M.delete_hunk(id, at, lines_removed)
	local lines = {}
	for i = 1, #lines_removed do
		lines[i] = "-" .. lines_removed[i]
	end
	return {
		id = id,
		old_start = at,
		old_lines = #lines_removed,
		new_start = at,
		new_lines = 0,
		lines = lines,
	}
end

---Insert `new_lines` before line `at`
---@param id string
---@param at number 1-indexed line in the base to insert before
---@param new_lines string[] lines to insert
---@return Hunk
function M.insert_hunk(id, at, new_lines)
	local lines = {}
	for i = 1, #new_lines do
		lines[i] = "+" .. new_lines[i]
	end
	return {
		id = id,
		old_start = at,
		old_lines = 0,
		new_start = at,
		new_lines = #new_lines,
		lines = lines,
	}
end

---True if the review buffer has a buffer-local normal-mode mapping for `lhs`
function M.has_keymap(buf, lhs)
	local want = lhs:lower()
	for _, m in ipairs(child.api.nvim_buf_get_keymap(buf, "n")) do
		if m.lhs:lower() == want then
			return true
		end
	end
	return false
end

return M
