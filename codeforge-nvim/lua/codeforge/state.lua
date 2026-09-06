local M = {}

M.changes = {}
M.current_change_id = nil
M.current_change_index = nil
M.expanded_files = {}
M.selected_path = nil
M.last_view_state = nil
M.reviews = {}
M.log = {}
M._on_change = nil

function M.reset()
	M.changes = {}
	M.current_change_id = nil
	M.current_change_index = nil
	M.expanded_files = {}
	M.reviews = {}
	M.log = {}
	M.selected_path = nil
	M.last_view_state = nil
end

---@alias Status
---| "'added'"
---| "'modified'"
---| "'deleted'"

---@class Change
---@field id string
---@field title string
---@field timestamp number
---@field status string
---@field files File[]

---@class File
---@field path string
---@field status Status
---@field hunks Hunk[]
---@field base string[]?
---@field decision string? "accepted"|"rejected"

---@class Hunk
---@field id string
---@field description string
---@field old_start number
---@field old_lines number
---@field new_start number
---@field new_lines number
---@field lines string[]
---@field status Status
---@field modified_content string|nil

---Get the review record for `path`, or nil if not under review.
---@param path string
---@return Review|nil
function M.get_review(path)
	return M.reviews[path]
end

---Store/replace the review record for `path`
---@param path string
---@param review Review
function M.set_review(path, review)
	M.reviews[path] = review
end

---Clear the review record for `path`.
---@param path string
function M.clear_review(path)
	M.reviews[path] = nil
end

-- Set a callback for when state changes
---@param callback function
function M.set_on_change(callback)
	M._on_change = callback
end

---Notify that state changed
function M.notify_change()
	if M._on_change then
		M._on_change()
	end
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

-- Select the previous change
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

-- Returns whether a file's hunks are expanded
---@param file_path string
---@return boolean
function M.is_expanded(file_path)
	local change = M.get_current_change()
	if not change then
		return false
	end

	local change_expanded = M.expanded_files[change.id] or {}
	return change_expanded[file_path] or false
end

-- Toggles whether a file's hunks should be expanded
---@param file_path string
function M.toggle_file(file_path)
	local change = M.get_current_change()
	if not change then
		return
	end

	if not M.expanded_files[change.id] then
		M.expanded_files[change.id] = {}
	end

	local current = M.expanded_files[change.id][file_path] or false
	M.expanded_files[change.id][file_path] = not current

	if M._on_change then
		M._on_change()
	end
end

---Find a change's 1-based position by id.
---@param id string
---@return number|nil
local function change_index(id)
	for i, change in ipairs(M.changes) do
		if change.id == id then
			return i
		end
	end
	return nil
end

---Build a decision log entry for a completed change.
---Captures: id, title, timestamp, derived status, and per-file outcomes.
---@param change Change
---@return table entry
function M.build_log_entry(change)
	local entry = {
		id = change.id,
		title = change.title,
		timestamp = os.time(),
		status = M.derive_status(change),
		files = {},
	}

	for _, file in ipairs(change.files or {}) do
		local review = M.reviews[file.path]
		local fentry = {
			path = file.path,
			status = file.status,
		}
		if file.status == "added" or file.status == "deleted" then
			fentry.decision = file.decision
		else
			fentry.modified = review and review.user_modified or nil
			fentry.hunks = {}
			for _, hunk in ipairs(file.hunks or {}) do
				fentry.hunks[#fentry.hunks + 1] = {
					id = hunk.id,
					status = review and review.hunk_status[hunk.id] or nil,
				}
			end
		end
		entry.files[#entry.files + 1] = fentry
	end
	return entry
end

---Append an entry to the in-memory decision log (and the on-disk log file).
---@param entry table
function M.append_log(entry)
	table.insert(M.log, entry)
	M.persist_log(entry)
end

---Write-through append of `entry` to `M.log_file` as a JSON array,
---Tolerates a missing/corrupt file (treated as empty).
---@param entry table
function M.persist_log(entry)
	if not M.log_file then
		return
	end

	local ok, err = pcall(function()
		local existing = {}
		local f = io.open(M.log_file, "r")
		if f then
			local raw = f:read("*a")
			f:close()
			local okd, decoded = pcall(vim.json.decode, raw)
			if okd and type(decoded) == "table" then
				existing = decoded
			end
		end
		existing[#existing + 1] = entry

		local dir = vim.fn.fnamemodify(M.log_file, ":h")
		vim.fn.mkdir(dir, "p")
		local out = io.open(M.log_file, "w")
		out:write(vim.json.encode(existing))
		out:close()
	end)
	if not ok then
		pcall(vim.notify, "CodeForge: failed to persist decision log: " .. tostring(err), vim.log.levels.WARN)
	end
end

---Find the tracked change containing `path`, or nil.
---@param path string
---@return Change|nil
function M.change_for_path(path)
	for _, change in ipairs(M.changes) do
		for _, file in ipairs(change.files or {}) do
			if file.path == path then
				return change
			end
		end
	end
	return nil
end

---Complete a fully-triaged change.
---@param change Change
function M.complete_change(change)
	if not change then
		return
	end

	local entry = M.build_log_entry(change)
	for _, file in ipairs(change.files or {}) do
		local review = M.reviews[file.path]
		if review then
			review:dismiss()
		end
	end
	M.remove_change(change.id, entry)
end

---Watch for completion: when `change`'s derived status has left `pending`,
---complete it.
---@param change Change
---@return boolean completed
function M.maybe_complete(change)
	if not change or not change.id then
		return false
	end

	for _, c in ipairs(M.changes) do
		if c == change then
			if M.derive_status(change) == "pending" then
				return false
			end
			M.complete_change(change)
			return true
		end
	end
	return false
end

---Remove the change with `id` from the change list.
---@param id string
---@param entry table?
---@return boolean removed true when a change with `id` existed
function M.remove_change(id, entry)
	local idx = change_index(id)
	if not idx then
		return false
	end

	local change = M.changes[idx]
	M.append_log(entry or M.build_log_entry(change))
	table.remove(M.changes, idx)
	M.expanded_files[id] = nil

	if M.current_change_index ~= nil then
		if idx < M.current_change_index then
			M.current_change_index = M.current_change_index - 1
		elseif idx == M.current_change_index then
			M.current_change_index = math.min(M.current_change_index, #M.changes)
			if #M.changes == 0 then
				M.current_change_index = nil
			end
		end

		local current = M.get_current_change()
		M.current_change_id = current and current.id or nil
	end

	M.notify_change()
	return true
end

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

---True when `file` needs no hunk-level review: a whole-file addition
---or a whole-file deletion.
---@param file File
---@return boolean
local function is_atomic(file)
	return file.status == "added" or file.status == "deleted"
end

---True when every part of `file` has been triaged.
---@param file File
---@return boolean
function M.file_completed(file)
	if is_atomic(file) then
		return file.decision ~= nil
	end

	local review = M.reviews[file.path]
	for _, hunk in ipairs(file.hunks or {}) do
		local st = review and review.hunk_status[hunk.id] or nil
		if st ~= "accepted" and st ~= "rejected" then
			return false
		end
	end
	return true
end

---Completion indicator for a sidebar file row: the hunk-review
---glyph for modified files, the file-level decision for added/
---deleted files.
---@param file File
---@return string glyph "●" completed | "○" pending
---@return string hl_group
function M.file_status_glyph(file)
	local hl = require("codeforge.highlight")
	if not M.file_completed(file) then
		return "○", hl.get_review_status_hl(nil)
	end
	if is_atomic(file) then
		return "●", hl.get_review_status_hl(file.decision)
	end
	local review = M.reviews[file.path]
	local all_accepted = true
	for _, hunk in ipairs(file.hunks or {}) do
		if not (review and review.hunk_status[hunk.id] == "accepted") then
			all_accepted = false
			break
		end
	end
	return "●", hl.get_review_status_hl(all_accepted and "accepted" or "modified")
end

---Derive a change's aggregate review status from its child hunks.
---  pending	-> any hunk still pending
---  accepted	-> all hunks accepted
---  rejected	-> all hunks rejected
---  modified	-> mixed accept/reject, or edited
---@param change Change
---@return "pending"|"accepted"|"rejected"|"modified"
function M.derive_status(change)
	local any_pending = false
	local any_accepted = false
	local any_rejected = false
	local user_modified = false

	for _, file in ipairs(change.files or {}) do
		local review = M.reviews[file.path]
		if review and review.user_modified then
			user_modified = true
		end
		if is_atomic(file) then
			if file.decision == "accepted" then
				any_accepted = true
			elseif file.decision == "rejected" then
				any_rejected = true
			else
				any_pending = true
			end
		else
			for _, hunk in ipairs(file.hunks or {}) do
				local st = review and review.hunk_status[hunk.id] or nil
				if st == "accepted" then
					any_accepted = true
				elseif st == "rejected" then
					any_rejected = true
				else
					any_pending = true
				end
			end
		end
	end

	if any_pending then
		return "pending"
	end
	if user_modified or (any_accepted and any_rejected) then
		return "modified"
	end
	if any_rejected then
		return "rejected"
	end
	return "accepted"
end

return M
