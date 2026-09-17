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
---@param base string[] the file's base (empty for added files)
---@param status string the file's status
---@param index integer position in the request (identity is assigned only on admission)
---@return string|nil error
local function validate_hunk(h, path, base, status, index)
	local context = ("path %s: hunk %d: "):format(path, index)
	local nbase = #base
	if type(h) ~= "table" then
		return context .. "hunk must be a table"
	end
	if h.id ~= nil then
		return context .. "id is assigned by Neovim; omit it from publish requests"
	end
	for _, key in ipairs({ "old_start", "old_lines", "new_start", "new_lines" }) do
		if not is_int(h[key]) then
			return context .. key .. " must be an integer"
		end
	end
	if h.old_start < 1 then
		return context .. "old_start must be >= 1"
	end
	if h.old_lines < 0 then
		return context .. "old_lines must be >= 0"
	end
	if h.new_start < 1 then
		return context .. "new_start must be >= 1"
	end
	if h.new_lines < 0 then
		return context .. "new_lines must be >= 0"
	end
	if status == "added" then
		if h.old_start ~= 1 or h.old_lines ~= 0 then
			return context .. "an added-file hunk starts at line 1 with nothing removed"
		end
	elseif h.old_start + h.old_lines - 1 > nbase then
		return context .. ("range extends past the end of base (%d lines)"):format(nbase)
	end
	local nlines = array_len(h.lines)
	if not nlines or nlines == 0 then
		return context .. "lines must be a non-empty list"
	end
	local nminus, nplus = 0, 0
	for l = 1, nlines do
		local line = h.lines[l]
		if type(line) ~= "string" then
			return context .. ("line %d must be a string"):format(l)
		end
		local prefix = line:sub(1, 1)
		if prefix == "-" then
			nminus = nminus + 1
		elseif prefix == "+" then
			nplus = nplus + 1
		else
			return context .. ("line %d has no +/- prefix: %s"):format(l, line)
		end
	end
	if nminus ~= h.old_lines then
		return context .. ("%d '-' lines but old_lines = %d"):format(nminus, h.old_lines)
	end
	if nplus ~= h.new_lines then
		return context .. ("%d '+' lines but new_lines = %d"):format(nplus, h.new_lines)
	end
	local row = h.old_start
	for _, line in ipairs(h.lines) do
		if line:sub(1, 1) == "-" then
			if line:sub(2) ~= base[row] then
				return context .. ("removed line does not match base line %d"):format(row)
			end
			row = row + 1
		end
	end
end

---@param file table file entry
---@return string|nil error
local function validate_file(file)
	if type(file) ~= "table" then
		return "file must be a table"
	end
	if file.id ~= nil then
		return "file id is assigned by Neovim; omit it from publish requests"
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
		for i = 1, nbase do
			if type(file.base[i]) ~= "string" then
				return ("path %s: base line %d must be a string"):format(path, i)
			end
		end
	end
	local nhunks = array_len(file.hunks)
	if not nhunks or nhunks == 0 then
		return ("path %s: hunks must be a non-empty list"):format(path)
	end
	if file.status == "added" and nhunks ~= 1 then
		return ("path %s: an added file takes exactly one hunk"):format(path)
	end
	local sorted = {}
	for j = 1, nhunks do
		local err = validate_hunk(file.hunks[j], path, file.base or {}, file.status, j)
		if err then
			return err
		end
		sorted[j] = j
	end
	-- Match apply_hunks' base-coordinate ordering without mutating the input.
	-- Ranges are half-open; adjacency is valid. Shared starts (including
	-- insertions) are ambiguous because application has no tie-break order.
	table.sort(sorted, function(a, b)
		return file.hunks[a].old_start < file.hunks[b].old_start
	end)
	for j = 2, nhunks do
		local prev, curr = file.hunks[sorted[j - 1]], file.hunks[sorted[j]]
		if curr.old_start == prev.old_start or curr.old_start < prev.old_start + prev.old_lines then
			return ("path %s: hunks %d and %d have overlapping or ambiguous base ranges"):format(
				path,
				sorted[j - 1],
				sorted[j]
			)
		end
	end
end

---Validate a change-set without ingesting it
---@param cs table publish request: {title?, files = [{ path, status, base?, hunks}]} (no ids)
---@return string|nil error nil when valid
function M.validate(cs)
	if type(cs) ~= "table" then
		return "change-set must be a table"
	end
	if cs.id ~= nil then
		return "change id is assigned by Neovim; omit it from publish requests"
	end
	if cs.title ~= nil and type(cs.title) ~= "string" then
		return "title must be a string when present"
	end
	local nfiles = array_len(cs.files)
	if not nfiles or nfiles == 0 then
		return "files must be a non-empty list"
	end
	for i = 1, nfiles do
		local err = validate_file(cs.files[i])
		if err then
			return ("file %d: %s"):format(i, err)
		end
	end
	return nil
end

---Derive a hunk's diff-type status from its lines: pure additions are
---"added", pure removals "deleted", mixed "modified". Sender-provided
---values are ignored: this is display metadata, not triage state.
---@param hunk table
---@return string status
local function derive_hunk_status(hunk)
	local plus, minus = 0, 0
	for _, line in ipairs(hunk.lines) do
		if line:sub(1, 1) == "+" then
			plus = plus + 1
		else
			minus = minus + 1
		end
	end
	if minus == 0 then
		return "added"
	end
	if plus == 0 then
		return "deleted"
	end
	return "modified"
end

-- A random editor-session prefix plus a monotonic sequence avoids clock-based
-- collisions and never reuses an identity after state.reset(). IDs are opaque
-- handles, not authorization tokens. Keep this private to admission.
local identity_prefix
local identity_sequence = 0

local function next_change_id(state)
	if not identity_prefix then
		local ok, bytes = pcall(vim.uv.random, 16)
		if not ok or type(bytes) ~= "string" or #bytes ~= 16 then
			return nil, "cannot allocate change identity: random source unavailable"
		end
		identity_prefix = "cf-" .. bytes:gsub(".", function(c)
			return ("%02x"):format(c:byte())
		end)
	end
	-- Also avoid identities retained across a module reload or state import.
	local used = {}
	for _, change in ipairs(state.changes) do
		used[change.id] = true
	end
	for id in pairs(state.completed) do
		used[id] = true
	end
	for _, entry in ipairs(state.log) do
		used[entry.id] = true
	end
	local id
	repeat
		identity_sequence = identity_sequence + 1
		id = identity_prefix .. "-" .. identity_sequence
	until not used[id]
	return id
end

---Publish a new change into `state.changes`; never replace an existing change.
---@param cs table publish request without change/file/hunk ids
---@return boolean ok
---@return table|string payload {id, files = [{path, hunks = [{id}]}]} or error string
function M.receive(cs)
	local err = M.validate(cs)
	if err then
		return false, err
	end
	local state = require("codeforge.state")

	-- `state.reviews` is keyed by path: a second pending change must not claim
	-- the same file. Publishing is create-only, even when retrying a request.
	local incoming = {}
	for _, file in ipairs(cs.files) do
		incoming[vim.fs.normalize(vim.fn.fnamemodify(file.path, ":p"))] = file.path
	end
	for _, change in ipairs(state.changes) do
		for _, file in ipairs(change.files or {}) do
			local path = vim.fs.normalize(vim.fn.fnamemodify(file.path, ":p"))
			if incoming[path] then
				return false,
					("path %q is already tracked by pending change %q; resolve it before re-sending"):format(
						incoming[path],
						change.id
					)
			end
		end
	end

	local change = vim.deepcopy(cs)
	change.timestamp = os.time()
	change.status = nil
	-- Resolve project-relative paths against the editor's cwd and derive
	-- display status; sender-supplied values for both are ignored.
	local seen = {}
	for _, file in ipairs(change.files) do
		file.path = vim.fs.normalize(vim.fn.fnamemodify(file.path, ":p"))
		if seen[file.path] then
			return false, ("duplicate file path %q"):format(file.path)
		end
		seen[file.path] = true
		file.decision = nil
		for _, hunk in ipairs(file.hunks) do
			hunk.status = derive_hunk_status(hunk)
		end
	end

	-- Allocate only after all validation/admission checks pass. Return a fresh
	-- receipt, in request order, with no references into the stored change.
	local id, id_err = next_change_id(state)
	if not id then
		return false, id_err
	end
	change.id = id
	change.title = change.title or id
	local ack = { id = id, files = {} }
	for i, file in ipairs(change.files) do
		local receipt = { path = file.path, hunks = {} }
		for j, hunk in ipairs(file.hunks) do
			hunk.id = ("%s-f%d-h%d"):format(id, i, j)
			receipt.hunks[j] = { id = hunk.id }
		end
		ack.files[i] = receipt
	end
	table.insert(state.changes, change)

	if state.current_change_id == nil then
		state.current_change_id = change.id
		state.current_change_index = #state.changes
	end

	state.notify_change()
	return true, ack
end

---Decode a JSON publish request and ingest it.
---@param json_str string
---@return boolean ok
---@return table|string payload structured receipt on success, error message on failure
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

---Read a JSON publish request from `path` and ingest it.
---@param path string
---@return boolean ok
---@return table|string payload structured receipt on success, error message on failure
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

---Throws on failure and returns the structured receipt.
---@param path string
---@return table ack
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
