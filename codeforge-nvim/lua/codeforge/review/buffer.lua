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

---Take over saving for a review buffer with `buftype=acwrite`
---@param buf integer
---@param path string
local function attach_save_guard(buf, path)
	vim.api.nvim_create_augroup("codeforge_save_guard", { clear = false })
	local ok, existing = pcall(vim.api.nvim_get_autocmds, {
		event = "BufWriteCmd",
		group = "codeforge_save_guard",
		buffer = buf,
	})
	if ok then
		for _, ac in ipairs(existing) do
			vim.api.nvim_del_autocmd(ac.id)
		end
	end
	local snapshot
	if vim.fn.filereadable(path) == 1 then
		snapshot = vim.fn.readfile(path)
	end
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = "codeforge_save_guard",
		buffer = buf,
		callback = function(args)
			local name = vim.api.nvim_buf_get_name(args.buf)
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local disk = vim.fn.filereadable(name) == 1 and vim.fn.readfile(name) or nil
			local disk_untouched = disk == nil or (snapshot ~= nil and vim.deep_equal(disk, snapshot))
			if not disk_untouched and not vim.deep_equal(disk, lines) then
				error("CodeForge: the file changed on disk since the review opened (use :e to inspect)", 0)
			end
			-- acwrite buffers are never written by vim's default path; do it
			-- ourselves: drop to a normal buftype so `write!` uses the standard
			-- machinery (eol/fileformat handling), with forceit skipping the
			-- changed-file check and noautocmd preventing recursion into this
			-- handler.
			vim.bo[args.buf].buftype = ""
			local ok, err = pcall(vim.cmd, "silent! noautocmd write!")
			vim.bo[args.buf].buftype = "acwrite"
			if not ok then
				error(tostring(err), 0)
			end
		end,
	})
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
function M.win_for_buf(buf)
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
	local w = M.win_for_buf(buf)
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

---Begin (or resume) reviewing `path`: snapshot, build, load into the real buffer.
---@param path string
---@return Review|nil review nil when no change covers `path`
function M.ensure_review(path)
	local existing = state.get_review(path)

	if existing then
		return existing
	end

	local file = find_file(path)
	if not file then
		vim.notify("CodeForge: no change for " .. path, vim.log.levels.WARN)
		return nil
	end

	buf = vim.fn.bufadd(path)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].swapfile = false
	if vim.fn.filereadable(path) == 1 then
		vim.fn.bufload(buf)
	end

	if vim.bo[buf].filetype == "" then
		local ft = vim.filetype.match({ filename = path })
		if ft then
			vim.bo[buf].filetype = ft
		end
	end

	attach_save_guard(buf, path)

	local base = file.base or base_from_status(file, buf)
	local review = Review.new(path, buf, base, file.hunks or {})
	review:open()
	return review
end

---Begin reviewing `path`: snapshot, build, load into the buffer
---and show it in the main window.
---@param path string
function M.open(path)
	local review = M.ensure_review(path)
	if not review then
		return
	end
	show_in_main(review.buf)
end

---Show an already-open review for `path` in the main window
---without re-snapshotting. No-op if no review is in progress.
---Use this to surface an existing review without the snapshot
---or build cost of `open`.
---@param path string
---@return boolean shown
function M.show_review(path)
	local review = state.get_review(path)
	if not review then
		return false
	end
	show_in_main(review.buf)
	return true
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
