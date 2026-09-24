---Session persistence: keep tracked changes and their triage across restarts.
---Persists only the inert description of a review: the change-sets needed to
---rebuild the proposal, the triage decisions, and view state. Buffer-level
---snapshots (`U`, `atomic_baseline`), undo history and `completed` history are
---not persisted.
local M = {}

local VERSION = 1
local VALID_STATUS = { added = true, modified = true, deleted = true }

---Configured session file, or nil when persistence is disabled.
local configured

---Serialized form of the last successful write, to avoid rewriting identical
---state on every notify.
local last_written

local attached = false
local previous_on_change

---@param v any
---@return boolean
local function is_array(v)
	if type(v) ~= "table" then
		return false
	end
	for k in pairs(v) do
		if type(k) ~= "number" or math.floor(k) ~= k or k < 1 then
			return false
		end
	end
	return true
end

---@param v any
---@return boolean
local function is_string_list(v)
	if not is_array(v) then
		return false
	end
	for _, line in ipairs(v) do
		if type(line) ~= "string" then
			return false
		end
	end
	return true
end

local function is_int(v)
	return type(v) == "number" and math.floor(v) == v
end

---Enable persistence to `path`, or disable it with `false`/`nil`.
---@param opt boolean|string|nil
---@return boolean ok
---@return string|nil error
function M.configure(opt)
	if opt == false or opt == nil then
		configured = nil
		last_written = nil
		return true
	end
	if type(opt) ~= "string" or #opt == 0 or opt:find("%z") then
		return false, "session must be false, nil, or a non-empty path without NUL bytes"
	end
	configured = vim.fs.normalize(vim.fn.fnamemodify(opt, ":p"))
	last_written = nil
	return true
end

---@return boolean
function M.enabled()
	return configured ~= nil
end

---The active session file path, or nil when disabled.
---@return string|nil
function M.path()
	return configured
end

---Copy the persisted fields of a hunk.
---@param hunk table
---@return table
local function copy_hunk(hunk)
	local out = {
		id = hunk.id,
		old_start = hunk.old_start,
		old_lines = hunk.old_lines,
		new_start = hunk.new_start,
		new_lines = hunk.new_lines,
		lines = vim.deepcopy(hunk.lines),
	}
	if hunk.description ~= nil then
		out.description = hunk.description
	end
	return out
end

---Copy the persisted fields of a file. `atomic_baseline` is excluded.
---@param file table
---@return table
local function copy_file(file)
	local out = {
		path = file.path,
		status = file.status,
		hunks = {},
	}
	for i, hunk in ipairs(file.hunks or {}) do
		out.hunks[i] = copy_hunk(hunk)
	end
	if file.base ~= nil then
		out.base = vim.deepcopy(file.base)
	end
	if file.decision ~= nil then
		out.decision = file.decision
	end
	if file.failures and #file.failures > 0 then
		out.failures = vim.deepcopy(file.failures)
	end
	return out
end

---Build the serializable snapshot of the current session.
---@return table
function M.snapshot()
	local state = require("codeforge.state")
	local snapshot = {
		version = VERSION,
		changes = {},
		triage = {},
		expanded_files = vim.deepcopy(state.expanded_files or {}),
		current_change_id = state.current_change_id,
	}

	for i, change in ipairs(state.changes) do
		local out = {
			id = change.id,
			title = change.title,
			timestamp = change.timestamp,
			files = {},
		}
		for j, file in ipairs(change.files or {}) do
			out.files[j] = copy_file(file)
			local triage = M._triage_for(file.path)
			if triage then
				snapshot.triage[file.path] = triage
			end
		end
		snapshot.changes[i] = out
	end

	return snapshot
end

---The triage record for `path`: live review state if one exists, else the
---restored description. Returns nil when nothing is known.
---@param path string
---@return table|nil
function M._triage_for(path)
	local state = require("codeforge.state")
	local review = state.reviews[path]
	if review then
		local hunk_status = {}
		for id, status in pairs(review.hunk_status or {}) do
			hunk_status[id] = status
		end
		return {
			hunk_status = hunk_status,
			user_modified = review.user_modified == true,
			expanded = vim.deepcopy(review.expanded or {}),
		}
	end
	local restored = state.triage[path]
	if restored then
		return vim.deepcopy(restored)
	end
	return nil
end

---Persist the snapshot. Skips the write when the state is unchanged since the
---last successful write.
---@return boolean written
function M.save()
	if not configured then
		return false
	end
	local snapshot = M.snapshot()
	local encoded = vim.json.encode(snapshot)
	if encoded == last_written then
		return false
	end

	if not pcall(vim.fn.mkdir, vim.fs.dirname(configured), "p") then
		return false
	end
	local ok = pcall(function()
		local out = assert(io.open(configured, "w"))
		out:write(encoded)
		out:close()
	end)
	if not ok then
		pcall(vim.notify, "CodeForge: failed to persist session", vim.log.levels.WARN)
		return false
	end
	last_written = encoded
	return true
end

---Validate one file entry. Returns an error string when unusable.
---@param file any
---@param context string
---@return string|nil
local function validate_file(file, context)
	if type(file) ~= "table" then
		return context .. " must be an object"
	end
	if type(file.path) ~= "string" or #file.path == 0 or file.path:find("%z") then
		return context .. " has no usable path"
	end
	if not VALID_STATUS[file.status] then
		return context .. " has no usable status"
	end
	if file.status ~= "added" then
		if not is_string_list(file.base) then
			return context .. " base must be a list of lines"
		end
	end
	if not is_array(file.hunks) then
		return context .. " hunks must be a list"
	end
	for i, hunk in ipairs(file.hunks) do
		local hc = ("%s hunk %d"):format(context, i)
		if type(hunk) ~= "table" or type(hunk.id) ~= "string" then
			return hc .. " has no usable id"
		end
		for _, key in ipairs({ "old_start", "old_lines", "new_start", "new_lines" }) do
			if not is_int(hunk[key]) then
				return hc .. " " .. key .. " must be an integer"
			end
		end
		if not is_string_list(hunk.lines) then
			return hc .. " lines must be a list of lines"
		end
	end
	if file.decision ~= nil and file.decision ~= "accepted" and file.decision ~= "rejected" then
		return context .. " has an invalid decision"
	end
	if file.failures ~= nil then
		if not is_array(file.failures) then
			return context .. " failures must be a list"
		end
		for _, failure in ipairs(file.failures) do
			if type(failure) ~= "table" or type(failure.reason) ~= "string" then
				return context .. " has a failure without a reason"
			end
		end
	end
	return nil
end

---Validate the whole snapshot before admitting any of it.
---@param snapshot any
---@return string|nil
local function validate_snapshot(snapshot)
	if type(snapshot) ~= "table" then
		return "snapshot must be an object"
	end
	if snapshot.version ~= VERSION then
		return ("unsupported session version %s"):format(tostring(snapshot.version))
	end
	if not is_array(snapshot.changes) then
		return "changes must be a list"
	end
	local seen = {}
	for i, change in ipairs(snapshot.changes) do
		local cc = ("change %d"):format(i)
		if type(change) ~= "table" or type(change.id) ~= "string" or #change.id == 0 then
			return cc .. " has no usable id"
		end
		if seen[change.id] then
			return cc .. " duplicates a change id"
		end
		seen[change.id] = true
		if not is_array(change.files) or #change.files == 0 then
			return cc .. " has no files"
		end
		local paths = {}
		for j, file in ipairs(change.files) do
			local err = validate_file(file, ("%s file %d"):format(cc, j))
			if err then
				return err
			end
			if paths[file.path] then
				return cc .. " duplicates a file path"
			end
			paths[file.path] = true
		end
	end
	if snapshot.triage ~= nil and type(snapshot.triage) ~= "table" then
		return "triage must be an object"
	end
	return nil
end

---Load the session file into state. Returns the number of restored changes,
---or 0 when there is nothing usable to restore. Does not clobber a change set
---that already exists in this session.
---@return integer restored
function M.load()
	if not configured then
		return 0
	end
	local f = io.open(configured, "r")
	if not f then
		return 0
	end
	local raw = f:read("*a")
	f:close()

	local decoded_ok, snapshot = pcall(vim.json.decode, raw)
	if not decoded_ok then
		pcall(vim.notify, "CodeForge: ignoring unreadable session file", vim.log.levels.WARN)
		return 0
	end
	local err = validate_snapshot(snapshot)
	if err then
		pcall(vim.notify, "CodeForge: ignoring invalid session file (" .. err .. ")", vim.log.levels.WARN)
		return 0
	end

	local state = require("codeforge.state")
	if #state.changes > 0 then
		return 0
	end

	-- Admit atomically: a refused entry must not leave a partial restore.
	local changes = {}
	local triage = {}
	for _, change in ipairs(snapshot.changes) do
		local out = {
			id = change.id,
			title = change.title or change.id,
			timestamp = change.timestamp,
			files = {},
		}
		for j, file in ipairs(change.files) do
			out.files[j] = copy_file(file)
			local restore = snapshot.triage and snapshot.triage[file.path]
			if restore then
				local known = {}
				for _, hunk in ipairs(out.files[j].hunks) do
					known[hunk.id] = true
				end
				local hunk_status = {}
				local any = false
				for id, status in pairs(restore.hunk_status or {}) do
					if known[id] and (status == "accepted" or status == "rejected" or status == "conflicted") then
						hunk_status[id] = status
						any = true
					end
				end
				local expanded = {}
				for id, value in pairs(restore.expanded or {}) do
					if known[id] and value == true then
						expanded[id] = true
					end
				end
				-- Admit the record when anything survived validation, including a
				-- pending fold's expansion.
				local describe = any or restore.user_modified == true or next(expanded) ~= nil
				if describe then
					triage[file.path] = {
						hunk_status = hunk_status,
						user_modified = restore.user_modified == true,
						expanded = expanded,
					}
				end
			end
		end
		changes[#changes + 1] = out
	end

	state.changes = changes
	state.triage = triage
	state.expanded_files = {}
	for id, files in pairs(snapshot.expanded_files or {}) do
		if type(id) == "string" and type(files) == "table" then
			state.expanded_files[id] = vim.deepcopy(files)
		end
	end
	if #changes > 0 then
		local index = 1
		for i, change in ipairs(changes) do
			if change.id == snapshot.current_change_id then
				index = i
				break
			end
		end
		state.current_change_index = index
		state.current_change_id = changes[index].id
	end
	state.notify_change()
	return #changes
end

---Persist on every state change and on exit. Safe to call once.
function M.attach()
	if attached then
		return
	end
	attached = true
	local state = require("codeforge.state")
	previous_on_change = state._on_change
	state.set_on_change(function()
		if previous_on_change then
			previous_on_change()
		end
		M.save()
	end)
	vim.api.nvim_create_augroup("codeforge_session", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = "codeforge_session",
		callback = function()
			M.save()
		end,
	})
end

---Drop cached write state (used by tests and `state.reset`).
function M.reset()
	last_written = nil
end

return M
