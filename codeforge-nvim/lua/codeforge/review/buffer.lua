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

---The window showing `buf`, or nil.
---@param buf integer
---@return integer|nil winid
function win_for_buf(buf)
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) == buf then
			return w
		end
	end
	return nil
end

---True if buf is the CodeForge sidebar
---@param buf integer
---@return boolean is_sidebar
local function is_sidebar_buf(buf)
	return vim.bo[buf].filetype == "codeforge"
end

---Show `buf` in the main editor window and focus it. If `buf` is already in a
---window, just focus that. Otherwise replace the contents of a non-sidebar
---window with `buf` and focus it.
local function show_in_main(buf)
	local w = win_for_buf(buf)
	if w then
		vim.api.nvim_set_current_win(w)
		return
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if not is_sidebar_buf(vim.api.nvim_win_get_buf(win)) then
			vim.api.nvim_win_set_buf(win, buf)
			vim.api.nvim_set_current_win(win)
			return
		end
	end

	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end

---Resolve the base content for `file`/`buf`. An added file has no base;
---a modified file without an explicit `base` falls back to the buffer's
---current content, treating a lone empty line as an empty file.
---@param file File
---@param buf integer
---@return string[] base
local function base_from_status(file, buf)
	if file.status == "added" then
		return {}
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if #lines == 1 and lines[1] == "" then
		return {}
	end
	return lines
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

	local base = file.base or base_from_status(file, buf)
	local review = Review.new(path, buf, base, file.hunks or {})
	review:open()
	show_in_main(buf)
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
