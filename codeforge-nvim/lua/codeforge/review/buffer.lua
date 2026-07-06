local state = require("codeforge.state")
local Review = require("codeforge.review.review")

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
	local abs = vim.fn.fnamemodify(path, ":p")
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p") == abs then
			return b
		end
	end

	return nil
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
		local ok = pcall(vim.api.nvim_buf_set_name, buf, path)
		if not ok then
			local abs = vim.fn.fnamemodify(path, ":p")
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p") == abs then
					buf = b
					break
				end
			end
		end
		if vim.fn.filereadable(path) == 1 then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path))
		end
		vim.bo[buf].buftype = ""
		vim.bo[buf].swapfile = false
	end

	local base = file.base or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local review = Review.new(path, buf, base, file.hunks or {})
	review:open()
end

---End reviewing `path`: restore the snapshotted buffer content and clear
---the review record.
---@param path string
function M.dismiss(path)
	local review = state.get_review(path)
	if not review then
		return
	end
	review:dismiss()
end

return M
