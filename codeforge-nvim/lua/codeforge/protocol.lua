---CodeForge's data-only wire API. Never dispatch a caller-provided function name.
local M = {}

function M.error(code, message)
	return { ok = false, error = { code = code, message = message:sub(1, 512) } }
end

local function keys_allowed(value, allowed, context)
	if type(value) ~= "table" then
		return context .. " must be an object"
	end
	for key in pairs(value) do
		if not allowed[key] then
			return context .. " contains an unsupported field"
		end
	end
end

-- Bound parser nesting before decoding. Brackets inside escaped JSON strings
-- are data, not structure. Syntax checking remains the JSON decoder's job.
local function shallow_enough(text)
	local depth, quoted, escaped = 0, false, false
	for i = 1, #text do
		local c = text:sub(i, i)
		if quoted then
			if escaped then
				escaped = false
			elseif c == "\\" then
				escaped = true
			elseif c == '"' then
				quoted = false
			end
		elseif c == '"' then
			quoted = true
		elseif c == "{" or c == "[" then
			depth = depth + 1
			if depth > 64 then
				return false
			end
		elseif c == "}" or c == "]" then
			depth = depth - 1
		end
	end
	return true
end

local proposal_fields = { title = true, files = true }
local file_fields = { path = true, status = true, base = true, hunks = true }
local hunk_fields = {
	old_start = true,
	old_lines = true,
	new_start = true,
	new_lines = true,
	lines = true,
	description = true,
}

local function wire_proposal_error(proposal)
	local err = keys_allowed(proposal, proposal_fields, "proposal")
	if err then
		return err
	end
	if type(proposal.files) ~= "table" then
		return "files must be a list"
	end
	if #proposal.files > 128 then
		return "at most 128 files are allowed per request"
	end
	local hunks = 0
	for _, file in ipairs(proposal.files) do
		err = keys_allowed(file, file_fields, "file")
		if err then
			return err
		end
		if type(file.path) == "string" and file.path:find("%z") then
			return "path contains a NUL byte"
		end
		if type(file.hunks) ~= "table" then
			return "hunks must be a list"
		end
		hunks = hunks + #file.hunks
		if hunks > 1024 then
			return "at most 1024 hunks are allowed per request"
		end
		for _, hunk in ipairs(file.hunks) do
			err = keys_allowed(hunk, hunk_fields, "hunk")
			if err then
				return err
			end
			for _, key in ipairs({ "old_start", "old_lines", "new_start", "new_lines" }) do
				local n = hunk[key]
				if type(n) == "number" and (n ~= n or n == math.huge or n == -math.huge) then
					return key .. " must be finite"
				end
			end
		end
	end
end

local request_fields = {
	publish = { op = true, proposal = true },
	status = { op = true, id = true },
	info = { op = true },
	list = { op = true, limit = true, cursor = true },
}

local MAX_LIST_LIMIT = 100
local DEFAULT_LIST_LIMIT = 20

---Decode a pagination cursor into the position it names. The cursor is opaque
---to clients: `v1:<timestamp>:<id>` identifies the *last row already seen*,
---which keeps paging stable while newer changes arrive at the front.
---@param value any
---@return table|nil position nil when malformed
---@return string|nil error
local function decode_cursor(value)
	if value == nil or value == vim.NIL then
		return { timestamp = math.huge, id = "\255" }
	end
	if type(value) ~= "string" or #value == 0 or #value > 512 or value:find("%z") then
		return nil, "cursor must be a non-empty string of at most 512 bytes without NUL bytes"
	end
	local version, timestamp, id = value:match("^([^:]+):([^:]+):(.+)$")
	if version ~= "v1" or not timestamp or not id then
		return nil, "cursor is not a valid CodeForge list cursor"
	end
	local n = tonumber(timestamp)
	if not n or n ~= math.floor(n) or n < 0 then
		return nil, "cursor is not a valid CodeForge list cursor"
	end
	return { timestamp = n, id = id }
end

---@param summary table
---@return string
local function encode_cursor(summary)
	return ("v1:%d:%s"):format(summary.timestamp or 0, summary.id)
end

---Summaries strictly older than `position`, newest first. Excluding by the
---full `(timestamp, id)` tuple is what makes an unchanged cursor resume at the
---same row even after new changes land at the front.
---@param summaries table[]
---@param position table
---@return table[]
local function after_cursor(summaries, position)
	local out = {}
	for _, summary in ipairs(summaries) do
		local ts, id = summary.timestamp or 0, summary.id
		local older = ts < position.timestamp or (ts == position.timestamp and id < position.id)
		if older then
			out[#out + 1] = summary
		end
	end
	return out
end

---Page over `state.known_changes()` newest-first.
---@param request table
---@return table
local function handle_list(request)
	local limit = request.limit
	if limit == nil then
		limit = DEFAULT_LIST_LIMIT
	end
	if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > MAX_LIST_LIMIT then
		return M.error("invalid_request", "limit must be an integer between 1 and " .. MAX_LIST_LIMIT)
	end
	local position, cursor_err = decode_cursor(request.cursor)
	if not position then
		return M.error("invalid_request", cursor_err)
	end

	local state = require("codeforge.state")
	local known = state._summarize_changes(state._read_log_raw())
	local summaries = after_cursor(known, position)
	local page = {}
	for i = 1, math.min(limit, #summaries) do
		page[i] = summaries[i]
	end
	local has_more = #summaries > #page
	return {
		ok = true,
		result = {
			changes = page,
			-- Total is of the whole known set, not the remaining pages, so a
			-- client can show progress without exhausting the list.
			total = #known,
			has_more = has_more,
			next_cursor = has_more and #page > 0 and encode_cursor(page[#page]) or vim.NIL,
		},
	}
end

---One bounded JSON frame, called on Neovim's main loop by socket.lua.
---Publish admits a proposal into memory; status only reads review outcomes.
function M.handle(frame)
	if not frame:match("^%s*{") or not shallow_enough(frame) then
		return M.error("invalid_request", "expected a JSON object with nesting at most 64")
	end
	local decoded, request = pcall(vim.json.decode, frame)
	if not decoded then
		return M.error("invalid_request", "invalid JSON")
	end
	if type(request.op) ~= "string" then
		return M.error("invalid_request", "op must be a string")
	end
	local allowed = request_fields[request.op]
	if not allowed then
		return M.error("unknown_operation", "only publish, status, info and list are supported")
	end
	local err = keys_allowed(request, allowed, "request")
	if err then
		return M.error("invalid_request", err)
	end
	if request.op == "info" then
		return { ok = true, result = require("codeforge.transport").info() }
	end
	if request.op == "list" then
		return handle_list(request)
	end
	if request.op == "status" then
		if type(request.id) ~= "string" or #request.id == 0 or #request.id > 256 or request.id:find("%z") then
			return M.error("invalid_request", "id must be a non-empty string of at most 256 bytes without NUL bytes")
		end
		local state = require("codeforge.state")
		local result = state.get_change_status(request.id) or state.get_persisted_status(request.id)
		if not result then
			return M.error("not_found", "change not found in this editor session")
		end
		return { ok = true, result = result }
	end
	err = wire_proposal_error(request.proposal)
	if err then
		return M.error("invalid_proposal", err)
	end
	local ok, payload = require("codeforge.transport").receive(request.proposal)
	if not ok then
		return M.error("invalid_proposal", payload)
	end
	return { ok = true, result = payload }
end

return M
