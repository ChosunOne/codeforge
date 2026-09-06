---Global undo/redo history for review actions.

local M = {}

---Committed transactions, oldest first.
M.undo_stack = {}

---Undone transactions, newest first.
M.redo_stack = {}

local open_frame = nil

function M.reset()
	M.undo_stack = {}
	M.redo_stack = {}
	open_frame = nil
end

---Begin grouping subsequent records into one undoable transaction.
---@param label string human-readable gesture name
function M.begin(label)
	if open_frame then
		return
	end
	open_frame = { label = label, records = {} }
end

---Commit the open transaction. Non-empty frames land on the undo stack
---and invalidate the redo stack.
function M.commit()
	if not open_frame then
		return
	end

	if #open_frame.records > 0 then
		M.undo_stack[#M.undo_stack + 1] = open_frame
		M.redo_stack = {}
	end
	open_frame = nil
end

---Record one state change. Automatically begins a transaction if
---one is not started already.
---@param rec table { kind, change_id, path, hunk_id?, before, after}
function M.record(rec)
	if not open_frame then
		M.begin(rec.kind or "action")
	end
	open_frame.records[#open_frame.records + 1] = rec
	M.commit()
end

return M
