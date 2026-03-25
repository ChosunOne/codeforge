local M = {}

M.changes = {}
M.current_change_id = nil
M.current_change_index = nil
M.expanded_files = {}
M.selected_path = nil
M.last_view_state = nil
M._on_change = nil

function M.reset()
	M.changes = {}
	M.current_change_id = nil
	M.current_change_index = nil
	M.expanded_files = {}
	M.selected_path = nil
	M.last_view_state = nil
end

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

-- Set a callback for when state changes
---@param callback function
function M.set_on_change(callback)
	M._on_change = callback
end

-- Get all changes
function M.get_changes()
	return M.changes
end

-- Get current change
---@return Change|nil
function M.get_current_change()
	return M.changes[M.current_change_index]
end

-- Get index of current change
---@return number
function M.get_change_index()
	return M.current_change_index or 0
end

-- Select the next change
function M.next_change()
	if #M.changes == 0 then
		return
	end

	M.current_change_index = math.max((M.current_change_index + 1) % (#M.changes + 1), 1)

	local change = M.get_current_change()
	if change then
		M.current_change_id = change.id
	end

	if M._on_change then
		M._on_change()
	end
end
function M.prev_change()
	if #M.changes == 0 then
		return
	end

	M.current_change_index = M.current_change_index - 1
	if M.current_change_index <= 0 then
		M.current_change_index = #M.changes
	end

	local change = M.get_current_change()
	if change then
		M.current_change_id = change.id
	end

	if M._on_change then
		M._on_change()
	end
end

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
