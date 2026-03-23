local M = {}

M.changes = {}
M.current_change_id = nil
M.expanded_files = {}
M.selected_path = nil
M.last_view_state = nil

---@class Change
---@field id string
---@field title string
---@field timestamp number
---@field status string
---@field files File[]

---@class File
---@field path string
---@field status string
---@field hunks Hunk[]

---@class Hunk
---@field id string
---@field description string
---@field old_start number
---@field old_lines number
---@field new_start number
---@field new_lines number
---@field lines string[]
---@field status string
---@field modified_content string|nil

-- Get all changes
function M.get_changes()
	return M.changes
end

-- Get current change
---@return Change|nil
function M.get_current_change()
	return nil
end

-- Get index of current change
---@return number
function M.get_change_index()
	return 0
end

function M.next_change() end
function M.prev_change() end

---@param id string
function M.select_change(id) end

---@param file_path string
---@return boolean
function M.is_expanded(file_path)
	return false
end

---@param file_path string
function M.toggle_file(file_path) end

---@param file_path string
function M.expand_file(file_path) end

---@param file_path string
function M.collapse_file(file_path) end

---@param hunk_id string
---@return string
function M.get_hunk_status(hunk_id)
	return "pending"
end

---@param hunk_id string
---@param status string
function M.set_hunk_status(hunk_id, status) end

return M
