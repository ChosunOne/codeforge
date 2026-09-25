---Filesystem effects for accepting newly added files.
---
---Reviewing a *modified* file needs no writes: the user saves when ready. A new
---file is different — there is no prior content to protect, and leaving it only
---in a buffer means `:w` fails with E212 when its parent directory does not
---exist. So accepting an added file creates the parent directories and writes
---the file, and the review has a real result on disk.
---
---Safety rules, in order:
---  1. Never overwrite. If the path exists in any form, the write is refused
---     and reported as a per-part failure rather than destroying content the
---     review never saw.
---  2. Create directories only as needed, and only under the target's own path.
---  3. Undo removes a file only when this module created it, so undoing a
---     refused or never-written accept can never delete a pre-existing file.

local M = {}

---Absolute, symlink-resolved form of `path` for comparison. Falls back to the
---lexical path when resolution fails (e.g. the file does not exist yet).
---@param path string
---@return string
local function canonical(path)
	local abs = vim.fn.fnamemodify(path, ":p")
	local resolved = vim.uv.fs_realpath(abs)
	if resolved then
		return vim.fs.normalize(resolved)
	end
	local missing = {}
	local probe = abs
	while true do
		local found = vim.uv.fs_realpath(probe)
		if found then
			local suffix = #missing > 0 and ("/" .. table.concat(missing, "/")) or ""
			return vim.fs.normalize(found .. suffix)
		end
		local parent = vim.fs.dirname(probe)
		if not parent or parent == probe then
			return vim.fs.normalize(abs)
		end
		table.insert(missing, 1, vim.fs.basename(probe))
		probe = parent
	end
end

---True when something already occupies `path` (file, directory, or symlink).
---
---`fs_stat` follows symlinks, so a dangling symlink would read as absent; the
---`fs_lstat` check catches that too. A dangling link is still an occupied path
---that must not be silently replaced.
---@param path string
---@return boolean occupied
local function occupied(path)
	if vim.uv.fs_lstat(path) ~= nil then
		return true
	end
	return vim.uv.fs_stat(path) ~= nil
end

---Create every missing parent directory of `path`.
---@param path string
---@return boolean ok
---@return string|nil reason
function M.ensure_parents(path)
	local dir = vim.fs.dirname(path)
	if dir == nil or dir == "" then
		return false, "cannot determine a parent directory"
	end
	if vim.fn.isdirectory(dir) == 1 then
		return true
	end
	local ok, err = pcall(vim.fn.mkdir, dir, "p")
	if not ok or vim.fn.isdirectory(dir) ~= 1 then
		return false, "cannot create directory " .. dir .. (err and (": " .. tostring(err)) or "")
	end
	return true
end

---Write `lines` to `path` as a new file, creating parent directories.
---
---Refuses to overwrite anything already at `path`. Returns the file so the
---caller can record it for undo. `created_dirs` reports the deepest directory
---this call made, so undo can prune empty ones.
---@param path string
---@param lines string[]
---@return boolean ok
---@return string|nil reason
---@return table|nil info { path = canonical path, dirs = created dir paths }
function M.create_file(path, lines)
	if occupied(path) then
		return false, "target already exists on disk; refusing to overwrite"
	end

	local want_dir = vim.fn.isdirectory(vim.fs.dirname(path)) ~= 1
	local ok, reason = M.ensure_parents(path)
	if not ok then
		return false, reason
	end
	if want_dir then
		if occupied(path) then
			return false, "target already exists on disk; refusing to overwrite"
		end
	end

	local write_ok, err = pcall(vim.fn.writefile, lines, path)
	if not write_ok then
		return false, "cannot write " .. path .. ": " .. tostring(err)
	end

	local dirs = {}
	local dir = vim.fs.dirname(path)
	while dir and dir ~= "" and dir ~= "." do
		dirs[#dirs + 1] = dir
		local parent = vim.fs.dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end

	return true, nil, { path = canonical(path), dirs = dirs }
end

---Remove a file this module created, then prune the directories it created.
---
---Pruning stops at the first non-empty directory, so anything the user (or
---another tool) put inside is preserved.
---@param info table { path = string, dirs = string[]? }
---@return boolean removed
function M.remove_created(info)
	if type(info) ~= "table" or type(info.path) ~= "string" then
		return false
	end
	local removed = false
	if vim.uv.fs_lstat(info.path) ~= nil then
		local ok = pcall(vim.fn.delete, info.path)
		removed = ok and vim.uv.fs_lstat(info.path) == nil
	end
	for _, dir in ipairs(info.dirs or {}) do
		if vim.fn.isdirectory(dir) == 1 then
			local entries = vim.fn.readdir(dir)
			if type(entries) == "table" and #entries == 0 then
				pcall(vim.fn.delete, dir, "d")
			else
				break
			end
		end
	end
	return removed
end

---The `created` record for a file that already exists on disk, with the
---directories an ancestor walk reaches. Used by the review save guard, whose
---`write!` created the file through Vim's own machinery rather than through
---`create_file`, so there is no return value to reuse.
---@param path string
---@param made_dirs boolean
---@return table info { path = canonical path, dirs = candidate dir paths }
function M.describe_created(path, made_dirs)
	local dirs = {}
	if made_dirs then
		local dir = vim.fs.dirname(path)
		while dir and dir ~= "" and dir ~= "." do
			dirs[#dirs + 1] = dir
			local parent = vim.fs.dirname(dir)
			if parent == dir then
				break
			end
			dir = parent
		end
	end
	return { path = canonical(path), dirs = dirs }
end

---The failure reason recorded when an accept cannot create its file.
M.OVERWRITE_REASON = "target already exists on disk; refusing to overwrite"

---Reconcile an `added` file's decision with the filesystem.
---
---This is the one place that decides whether a new file exists on disk, so the
---review buffer path (`<C-x>a`), the sidebar decision path and undo/redo all
---agree.
---@param change Change|nil
---@param file File
---@param decision string|nil "accepted"|"rejected"|nil
---@param lines string[] content to write when accepting
---@return boolean ok
function M.sync_added_file(change, file, decision, lines)
	local state = require("codeforge.state")

	if decision ~= "accepted" then
		if file.created then
			M.remove_created(file.created)
			file.created = nil
		end
		state.clear_file_failure(file, M.OVERWRITE_REASON)
		return true
	end

	if file.created then
		return true
	end

	local ok, reason, info = M.create_file(file.path, lines)
	if ok then
		file.created = info
		state.clear_file_failure(file, M.OVERWRITE_REASON)
		return true
	end
	state.mark_file_failed(change and change.id, file.path, reason or "cannot create file")
	return false
end

return M
