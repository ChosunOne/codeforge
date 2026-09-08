---Ingest side of the transport: validate and admit a change-set received from an agent.
local M = {}

local VALID_STATUS = { added = true, modified = true, deleted = true }

M.active_socket = nil

---Element count if `v` is an array-like table, else nil.
---@param v any
---@return number|nil
local function array_len(v)
	if type(v) ~= "table" then
		return nil
	end
	local n = 0
	for k in pairs(v) do
		if type(k) ~= "number" or math.floor(k) ~= k or k < 1 then
			return nil
		end
		if k > n then
			n = k
		end
	end
	local seen = 0
	for _ in ipairs(v) do
		seen = seen + 1
	end
	if seen ~= n then
		return nil
	end
	return n
end

local function is_int(v)
	return type(v) == "number" and math.floor(v) == v
end

---@param h table hunk
---@param path string file path
---@param nbase number line count of the file's base
---@param status string the file's status
---@param hunk_ids table<string, boolean>
---@return string|nil error
local function validate_hunk(h, path, nbase, status, hunk_ids)
	if type(h) ~= "table" then
		return "hunk must be a table"
	end
	if type(h.id) ~= "string" or #h.id == 0 then
		return ("path %s: hunk needs a non-empty string id"):format(path)
	end
	if hunk_ids[h.id] then
		return ("path %s: duplicate hunk id %q"):format(path, h.id)
	end
	hunk_ids[h.id] = true
	for _, key in ipairs({ "old_start", "old_lines", "new_start", "new_lines" }) do
		if not is_int(h[key]) then
			return ("path %s hunk %q: %s must be an integer"):format(path, h.id, key)
		end
	end
	if h.old_start < 1 then
		return ("path %s hunk %q: old_start must be >= 1"):format(path, h.id)
	end
	if h.old_lines < 0 then
		return ("path %s hunk %q: old_lines must be >= 0"):format(path, h.id)
	end
	if h.new_start < 1 then
		return ("path %s hunk %q: new_start must be >= 1"):format(path, h.id)
	end
	if h.new_lines < 0 then
		return ("path %s hunk %q: new_lines must be >= 0"):format(path, h.id)
	end
	if status == "added" then
		if h.old_start ~= 1 or h.old_lines ~= 0 then
			return ("path %s hunk %q: an added-file hunk starts at line 1 with nothing removed"):format(path, h.id)
		end
	elseif h.old_start + h.old_lines - 1 > nbase then
		return ("path %s hunk %q: range extends past the end of base (%d lines)"):format(path, h.id, nbase)
	end
	local nlines = array_len(h.lines)
	if not nlines or nlines == 0 then
		return ("path %s hunk %q: lines must be a non-empty list"):format(path, h.id)
	end
	local nminus, nplus = 0, 0
	for l = 1, nlines do
		local line = h.lines[l]
		if type(line) ~= "string" then
			return ("path %s hunk %q: line %d must be a string"):format(path, h.id, l)
		end
		local prefix = line:sub(1, 1)
		if prefix == "-" then
			nminus = nminus + 1
		elseif prefix == "+" then
			nplus = nplus + 1
		else
			return ("path %s hunk %q: line %d has no +/- prefix: %s"):format(path, h.id, l, line)
		end
	end
	if nminus ~= h.old_lines then
		return ("path %s hunk %q: %d '-' lines but old_lines = %d"):format(path, h.id, nminus, h.old_lines)
	end
	if nplus ~= h.new_lines then
		return ("path %s hunk %q: %d '+' lines but new_lines = %d"):format(path, h.id, nplus, h.new_lines)
	end
end

---@param file table file entry
---@param hunk_ids table<string, boolean> ids seen anywhere in the change
---@return string|nil error
local function validate_file(file, hunk_ids)
	if type(file) ~= "table" then
		return "file must be a table"
	end
	if type(file.path) ~= "string" or #file.path == 0 then
		return "file needs a non-empty string path"
	end
	local path = file.path
	if not VALID_STATUS[file.status] then
		return ("path %s: status must be 'added', 'modified', or 'deleted'"):format(path)
	end
	local nbase = 0
	if file.status == "added" then
		if file.base ~= nil then
			return ("path %s: an added file must not carry a base"):format(path)
		end
	else
		nbase = array_len(file.base)
		if nbase == nil then
			return ("path %s: base must be a list of lines"):format(path)
		end
	end
	local nhunks = array_len(file.hunks)
	if not nhunks or nhunks == 0 then
		return ("path %s: hunks must be a non-empty list"):format(path)
	end
	if file.status == "added" and nhunks ~= 1 then
		return ("path %s: an added file takes exactly one hunk"):format(path)
	end
	for j = 1, nhunks do
		local err = validate_hunk(file.hunks[j], path, nbase, file.status, hunk_ids)
		if err then
			return err
		end
	end
end

---Validate a change-set without ingesting it
---@param cs table change-set: {id, title?, files = [{ path, status, base?, hunks}]}
---@return string|nil error nil when valid
function M.validate(cs)
	if type(cs) ~= "table" then
		return "change-set must be a table"
	end
	if type(cs.id) ~= "string" or #cs.id == 0 then
		return "change-set needs a non-empty string id"
	end
	if cs.title ~= nil and type(cs.title) ~= "string" then
		return "title must be a string when present"
	end
	local nfiles = array_len(cs.files)
	if not nfiles or nfiles == 0 then
		return "files must be a non-empty list"
	end
	local hunk_ids = {}
	for i = 1, nfiles do
		local err = validate_file(cs.files[i], hunk_ids)
		if err then
			return ("file %d: %s"):format(i, err)
		end
	end
	return nil
end

---Ingest a change-set into `state.changes`.
---@param cs table change-set
---@return boolean ok
---@return string|nil err
function M.receive(cs)
	local err = M.validate(cs)
	if err then
		return false, err
	end
	local state = require("codeforge.state")
	if state.completed[cs.id] then
		return false, ("change %q is already completed; send a new id"):format(cs.id)
	end

	local existing_index
	for i, change in ipairs(state.changes) do
		if change.id == cs.id then
			existing_index = i
			break
		end
	end
	if existing_index then
		for _, file in ipairs(state.changes[existing_index].files) do
			if state.reviews[file.path] then
				return false,
					("change %q has a file under review (%s); resolve it before re-sending"):format(cs.id, file.path)
			end
		end
	end

	local change = vim.deepcopy(cs)
	change.title = change.title or change.id
	change.timestamp = os.time()
	change.status = nil
	for _, file in ipairs(change.files) do
		file.decision = nil
		for _, hunk in ipairs(file.hunks) do
			hunk.status = nil
		end
	end

	if existing_index then
		state.changes[existing_index] = change
	else
		table.insert(state.changes, change)
	end

	if state.current_change_id == nil then
		state.current_change_id = change.id
		state.current_change_index = existing_index or #state.changes
	end

	state.notify_change()
	local nfiles = #change.files
	return true, ("received change %s (%d %s)"):format(change.id, nfiles, nfiles == 1 and "file" or "files")
end

---Decode a JSON change-set and ingest it
---@param json_str string
---@return boolean ok
---@return string|nil payload ack string on success, error message on failure
function M.receive_json(json_str)
	if type(json_str) ~= "string" then
		return false, "change-set JSON must be a string"
	end
	local ok, cs = pcall(vim.json.decode, json_str)
	if not ok then
		return false, ("invalid change-set JSON: %s"):format(cs)
	end
	if type(cs) ~= "table" then
		return false, "change-set JSON must decode to an object"
	end
	return M.receive(cs)
end

---Read a JSON change-set from `path` and ingest it.
---@param path string
---@return boolean ok
---@return string|nil payload ack string on success, error message on failure
function M.receive_file(path)
	if type(path) ~= "string" or #path == 0 then
		return false, "path must be a non-empty string"
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return false, ("cannot read %s: %s"):format(path, tostring(lines))
	end
	local ok2, payload = M.receive_json(table.concat(lines, "\n"))
	if not ok2 then
		return false, ("%s: %s"):format(path, payload)
	end
	return true, payload
end

---Throws on failure and returns the ack string
---@param path string
---@return string ack
function M.receive_file_strict(path)
	local ok, payload = M.receive_file(path)
	if not ok then
		error(payload, 0)
	end
	return payload
end

---Checks if running on windows machine
---@return boolean
function M._is_windows()
	return vim.fn.has("win32") == 1
end

---Platform appropriate default address for the RPC socket
---@return string
local function default_socket_path()
	if M._is_windows() then
		local user = vim.uv.os_getenv("USERNAME") or vim.uv.os_getenv("USER") or "default"
		user = user:gsub("[^%w%-_]", "")
		return "\\\\.\\pipe\\codeforge-" .. user .. ".sock"
	end
	local run = vim.fn.stdpath("run"):gsub("/+$", "")
	return run .. "/codeforge.sock"
end

---Address of the active RPC socket, or the default path when none is active.
---@return string
function M.socket_path()
	if type(M.active_socket) == "string" then
		return M.active_socket
	end
	return default_socket_path()
end

---Resolve a group name to its gid via /etc/group
---@param name string
---@return number|nil gid
local function gid_for_group(name)
	local ok, lines = pcall(vim.fn.readfile, "/etc/group")
	if not ok then
		return nil
	end
	for _, line in ipairs(lines) do
		local gname, gid = line:match("^([^:]+):[^:]*:(%d+):")
		if gname == name then
			return tonumber(gid)
		end
	end
	return nil
end

---@param path string
---@param opt table with optional `group` and `mode`
local function share_socket(path, opt)
	if M._is_windows() then
		if opt.group ~= nil or opt.mode ~= nil then
			vim.notify(
				"codeforge: socket group/mode sharing is not supported on Windows named pipes",
				vim.log.levels.WARN
			)
		end
		return
	end
	if opt.group ~= nil then
		local gid = gid_for_group(opt.group)
		if gid == nil then
			vim.notify(("codeforge: socket group %q not found"):format(tostring(opt.group)), vim.log.levels.WARN)
		else
			local ok2, err = pcall(vim.uv.fs_chown, path, -1, gid)
			if not ok2 then
				vim.notify(
					("codeforge: could not set socket group to %q: %s"):format(tostring(opt.group), tostring(err)),
					vim.log.levels.WARN
				)
			end
		end
	end
	if opt.mode ~= nil then
		local mode = tonumber(opt.mode, 8)
		if not mode then
			vim.notify(("codeforge: socket mode %q is not octal"):format(tostring(opt.mode)), vim.log.levels.WARN)
		else
			local ok3, err = pcall(vim.uv.fs_chmod, path, mode)
			if not ok3 then
				vim.notify(
					("codeforge: could not set socket mode to %s: %s"):format(tostring(opt.mode), tostring(err)),
					vim.log.levels.WARN
				)
			end
		end
	end
end

---Start or stop the RPC socket to receive change-sets through
---@param opt boolean|string|table|nil
function M.setup_socket(opt)
	if opt == false then
		if M.active_socket then
			pcall(vim.fn.serverstop, M.active_socket)
		end
		M.active_socket = nil
		return
	end
	local path
	if type(opt) == "table" then
		if type(opt.path) ~= "string" or #opt.path == 0 then
			vim.notify("codeforge: socket table option needs a non-empty string path", vim.log.levels.WARN)
			return
		end
		path = opt.path
	else
		path = type(opt) == "string" and opt or default_socket_path()
	end
	if M.active_socket == path and vim.list_contains(vim.fn.serverlist(), path) then
		return
	end
	if not vim.list_contains(vim.fn.serverlist(), path) then
		local ok, addr = pcall(vim.fn.serverstart, path)
		if not (ok and addr ~= "") then
			vim.notify(
				("codeforge: could not start RPC socket at %s (%s)"):format(path, tostring(addr)),
				vim.log.levels.WARN
			)
			return
		end
	end
	M.active_socket = path
	if type(opt) == "table" then
		share_socket(path, opt)
	end
end

return M
