---Global undo/redo history for review actions.

local M = {}

---Committed transactions, oldest first.
M.undo_stack = {}

---Undone transactions, newest first.
M.redo_stack = {}

local open_frames = {}

function M.reset()
	M.undo_stack = {}
	M.redo_stack = {}
	open_frames = {}
end

---Begin grouping subsequent records into one undoable transaction.
---@param label string human-readable gesture name
function M.begin(label)
	open_frames[#open_frames + 1] = { label = label, records = {} }
end

---Commit the open transaction. Non-empty frames land on the undo stack
---and invalidate the redo stack.
function M.commit()
	local frame = table.remove(open_frames)
	if not frame then
		return
	end
	if #open_frames > 0 then
		local parent = open_frames[#open_frames]
		for _, rec in ipairs(frame.records) do
			parent.records[#parent.records + 1] = rec
		end
		return
	end
	if #frame.records > 0 then
		M.undo_stack[#M.undo_stack + 1] = frame
		M.redo_stack = {}
	end
end

---Record one state change into the innermost open frame.
---If a frame is not currently open, the record becomes its own single-action transaction.
---@param rec table { kind, change_id, path, hunk_id?, before, after}
function M.record(rec)
	local implicit = #open_frames == 0
	if implicit then
		M.begin(rec.kind or "action")
	end
	local frame = open_frames[#open_frames]
	frame.records[#frame.records + 1] = rec
	if implicit then
		M.commit()
	end
end

---Pop the newest transaction onto the redo stack and return it.
---@return table|nil transaction
function M.pop_undo()
	local tx = table.remove(M.undo_stack)
	if tx then
		M.redo_stack[#M.redo_stack + 1] = tx
	end
	return tx
end

---Pop the newest redo transaction back onto the undo stack and return it.
---@return table|nil transaction

function M.pop_redo()
	local tx = table.remove(M.redo_stack)
	if tx then
		M.undo_stack[#M.undo_stack + 1] = tx
	end
	return tx
end

---Drop every transaction containing records for `change_id`.
---@param change_id string
function M.purge_change(change_id)
	local function keep(tx)
		for _, rec in ipairs(tx.records) do
			if rec.change_id == change_id then
				return false
			end
		end
		return true
	end

	local function filter(stack)
		local out = {}
		for _, tx in ipairs(stack) do
			if keep(tx) then
				out[#out + 1] = tx
			end
		end
		return out
	end

	M.undo_stack = filter(M.undo_stack)
	M.redo_stack = filter(M.redo_stack)
end

return M
