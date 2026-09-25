local state = require("codeforge.state")
local Review = require("codeforge.review.review")

local M = {}

---Per-buffer review save state: `save_guards[buf]` is the BufWriteCmd autocmd
---id; `buf_options[buf]` the buffer options captured before the review loaded
---its proposal.
M.save_guards = {}
M.buf_options = {}

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

---Record a path this guard wrote as CodeForge-created, so a later accept knows
---the file is ours rather than a foreign path to refuse.
---@param path string
---@param created_dirs boolean whether this write may have made directories
local function record_created(path, created_dirs)
	local change = require("codeforge.state").change_for_path(path)
	for _, file in ipairs(change and change.files or {}) do
		if file.path == path and file.status == "added" then
			file.created = require("codeforge.review.fs").describe_created(path, created_dirs)
			return
		end
	end
end

---Take over saving for a review buffer with `buftype=acwrite`.
---
---Snapshots the disk state on attach and again after every successful write, so
---consecutive normal saves during review are allowed while an external change to
---disk is refused.
---@param buf integer
---@param path string
---@param opts? table captured buffer options
---@param creates? boolean this buffer is a new file
local function attach_save_guard(buf, path, opts, creates)
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
	local autocmd = vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = "codeforge_save_guard",
		buffer = buf,
		callback = function(args)
			local name = vim.api.nvim_buf_get_name(args.buf)
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			local was_absent = vim.fn.filereadable(name) == 0
			local parents_may_be_new = was_absent and vim.fn.isdirectory(vim.fs.dirname(name)) ~= 1
			local disk = vim.fn.filereadable(name) == 1 and vim.fn.readfile(name) or nil
			local disk_untouched = disk == nil or (snapshot ~= nil and vim.deep_equal(disk, snapshot))
			if not disk_untouched and not vim.deep_equal(disk, lines) then
				error("CodeForge: the file changed on disk since the review opened (use :e to inspect)", 0)
			end
			if creates and vim.fn.filereadable(name) == 0 then
				local ok_dir, reason = require("codeforge.review.fs").ensure_parents(name)
				if not ok_dir then
					error("CodeForge: " .. (reason or "cannot create parent directories"), 0)
				end
			end
			-- acwrite buffers are never written by vim's default path; do it
			-- ourselves: drop to a normal buftype so `write!` uses the standard
			-- machinery (eol/fileformat handling). Hooks are driven with
			-- `doautocmd` (not `nvim_exec_autocmds`, which swallows callback
			-- errors) so a failing BufWritePre aborts the write and a failing
			-- BufWritePost still surfaces. `noautocmd write!` prevents recursion
			-- into this handler; the buftype is always restored.
			local prev_buftype = vim.bo[args.buf].buftype
			vim.bo[args.buf].buftype = ""
			local pre_ok, pre_err = pcall(vim.api.nvim_buf_call, args.buf, function()
				vim.cmd("doautocmd BufWritePre")
			end)
			local wok, werr = true, nil
			local post_ok, post_err = true, nil
			if pre_ok then
				wok, werr = pcall(vim.cmd, "noautocmd write!")
			end
			if pre_ok and wok then
				post_ok, post_err = pcall(vim.api.nvim_buf_call, args.buf, function()
					vim.cmd("doautocmd BufWritePost")
				end)
			end
			if vim.api.nvim_buf_is_valid(args.buf) then
				vim.bo[args.buf].buftype = prev_buftype
			end
			if wok and vim.fn.filereadable(name) == 1 then
				snapshot = vim.fn.readfile(name)
				if creates and was_absent then
					record_created(name, parents_may_be_new)
				end
			end
			if not pre_ok then
				error(tostring(pre_err), 0)
			end
			if not wok then
				error(tostring(werr), 0)
			end
			if not post_ok then
				error(tostring(post_err), 0)
			end
		end,
	})
	M.buf_options[buf] = opts
	M.save_guards[buf] = autocmd
end

---Release the review's save guard for `buf`, restoring the buffer options the
---review changed (`buftype`, `swapfile`). Idempotent.
---@param buf integer
function M.detach_save_guard(buf)
	local autocmd = M.save_guards[buf]
	if autocmd then
		pcall(vim.api.nvim_del_autocmd, autocmd)
		M.save_guards[buf] = nil
	end
	local opts = M.buf_options[buf]
	M.buf_options[buf] = nil
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if opts then
		vim.bo[buf].buftype = opts.buftype or ""
		vim.bo[buf].swapfile = opts.swapfile
	end
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

---Assert that `path` is reviewable right now. Fails closed, and reports the
---reason to the caller so it can be recorded as a per-part failure.
---@param path string
---@return boolean ok
---@return string|nil reason
local function check_reviewable(path)
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return false, "target no longer exists on disk"
	end
	if stat.type ~= "file" then
		return false, "target is not a regular file on disk"
	end
	if not vim.uv.fs_access(path, "R") then
		return false, "target is not readable"
	end
	return true
end

---Begin (or resume) reviewing `path`: snapshot, build, load into the real buffer.
---@param path string
---@return Review|nil review nil when no change covers `path` or the part failed
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

	if file.status == "modified" then
		local ok, reason = check_reviewable(path)
		if not ok then
			local change = state.change_for_path(path)
			if change then
				state.mark_file_failed(change.id, path, reason)
			end
			vim.notify("CodeForge: cannot review " .. path .. ": " .. reason, vim.log.levels.WARN)
			return nil
		end
	end

	buf = vim.fn.bufadd(path)
	local opts = { buftype = vim.bo[buf].buftype, swapfile = vim.bo[buf].swapfile }
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

	attach_save_guard(buf, path, opts, file.status == "added")

	local base = file.base or base_from_status(file, buf)
	local review = Review.new(path, buf, base, file.hunks or {})
	local triage = state.triage[path]
	if triage then
		state.triage[path] = nil
		review:restore_triage(triage)
	end
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

---Show an already-open review for `path` in the main window.
---No-op if no review is in progress. Use this to surface an existing review
---without the snapshot or build cost of `open`.
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

---Re-arm the review save guard and buffer options for a revived review
---(undo after the completing action dismissed it). Idempotent-ish: the
---existing guard, if any, is replaced.
---@param path string
---@param buf integer
function M.rearm_review(path, buf)
	local opts = { buftype = vim.bo[buf].buftype, swapfile = vim.bo[buf].swapfile }
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].swapfile = false
	local creates = false
	local file = find_file(path)
	if file then
		creates = file.status == "added"
	end
	attach_save_guard(buf, path, opts, creates)
end

---End reviewing `path`: restore the snapshotted buffer content and clear
---the review record. Returns false when assembly is unsafe (a conflicting gap
---between pre-review and during-review edits): the review is kept so no side
---is silently discarded.
---@param path string
---@return boolean finished
function M.dismiss(path)
	local review = state.get_review(path)
	if not review then
		return true
	end
	return review:dismiss()
end
return M
