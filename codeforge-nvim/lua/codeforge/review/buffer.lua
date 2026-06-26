local state = require("codeforge.state")

local M = {}

---Find the file entry for `path` in the current change, or nil
---@param path string
---@return File|nil
local function find_file(path)
	local change = state.get_current_change()
	if not change or not change.files then
		return nil
	end
	for _, file in ipairs(change.files) do
		if file.path == path then
			return file
		end
	end

	return nil
end

---Find an already-loaded buffer for `path`, or nil.
---@param path string
---@return integer|nil bufnr
local function find_loaded_buf(path)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(b) == path then
			return b
		end
	end

	return nil
end

---Build the proposal by applying `hunks` to `base`
---Hunks use jj/unified diff format: lines prefixed " " context, "-" removed
---"+" added. old_start is 1-indexed in `base`
---@param base string[]
---@param hunks Hunk[]
---@return string[] proposal
local function apply_hunks(base, hunks)
	local out = { unpack(base) } ---@type string[]
	table.sort(hunks, function(a, b)
		return a.old_start < b.old_start
	end)
	for i = #hunks, 1, -1 do
		local h = hunks[i]
		local start = h.old_start
		local removed = h.old_lines
		local replacement = {} ---@type string[]
		for _, line in ipairs(h.lines) do
			local prefix = line:sub(1, 1)
			if prefix == "+" then
				replacement[#replacement + 1] = line:sub(2)
			elseif prefix == " " then
				replacement[#replacement + 1] = line:sub(2)
			end
		end

		local before = {}
		for j = 1, start - 1 do
			before[j] = out[j]
		end
		local after = {}
		for j = start + removed, #out do
			after[#after + 1] = out[j]
		end
		local result = {} ---@type string[]
		for _, l in ipairs(before) do
			result[#result + 1] = l
		end
		for _, l in ipairs(replacement) do
			result[#result + 1] = l
		end
		for _, l in ipairs(after) do
			result[#result + 1] = l
		end
		out = result
	end
	return out
end

---Begin reviewing `path`: snapshot, build, load into the real buffer.
---@param path string
function M.open(path)
	local file = find_file(path)
	if not file then
		vim.notify("CodeForge: no change for " .. path, vim.log.levels.WARN)
		return
	end

	local buf = find_loaded_buf(path)
	if not buf then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, path)
		local lines = {}
		if vim.fn.filereadable(path) == 1 then
			lines = vim.fn.readfile(path)
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].buftype = ""
		vim.bo[buf].swapfile = false
	end

	local buf_snapshot = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local base_content = file.base or buf_snapshot
	local proposal = apply_hunks(vim.deepcopy(base_content), file.hunks or {})

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, proposal)

	state.set_review(path, {
		real_bufnr = buf,
		buf_snapshot = buf_snapshot,
		base_content = base_content,
		hunks = file.hunks or {},
	})
end

---End reviewing `path`: restore the snapshotted buffer content and clear
---the review record.
---@param path string
function M.dismiss(path)
	local review = state.get_review(path)
	if not review then
		return
	end
	local buf = review.real_bufnr
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, review.buf_snapshot)
	end
	state.clear_review(path)
end

return M
