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
local hunk_fields = { old_start = true, old_lines = true, new_start = true, new_lines = true, lines = true }

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

---One bounded JSON frame, called on Neovim's main loop by socket.lua.
---The only remotely available action is publishing a proposal into memory.
function M.handle(frame)
	if not frame:match("^%s*{") or not shallow_enough(frame) then
		return M.error("invalid_request", "expected a JSON object with nesting at most 64")
	end
	local decoded, request = pcall(vim.json.decode, frame)
	if not decoded then
		return M.error("invalid_request", "invalid JSON")
	end
	local err = keys_allowed(request, { op = true, proposal = true }, "request")
	if err then
		return M.error("invalid_request", err)
	end
	if type(request.op) ~= "string" then
		return M.error("invalid_request", "op must be a string")
	end
	if request.op ~= "publish" then
		return M.error("unknown_operation", "only publish is supported")
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
