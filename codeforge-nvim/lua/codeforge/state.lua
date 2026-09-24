local M = {}

M.changes = {}
M.current_change_id = nil
M.current_change_index = nil
M.expanded_files = {}
M.reviews = {}
M.triage = {}
M.log = {}
M.completed = {}
M.completed_order = {}
M._on_change = nil

function M.reset()
	M.changes = {}
	M.current_change_id = nil
	M.current_change_index = nil
	M.expanded_files = {}
	M.reviews = {}
	M.triage = {}
	M.log = {}
	M.completed = {}
	M.completed_order = {}
	M.invalidate_log_cache()
	require("codeforge.history").reset()
end

---@alias Status
---| "'added'"
---| "'modified'"
---| "'deleted'"

---@class Change
---@field id string
---@field title string
---@field timestamp number
---@field status string
---@field files File[]

---@class File
---@field path string
---@field status Status
---@field hunks Hunk[]
---@field base string[]?
---@field decision string? "accepted"|"rejected"
---@field atomic_baseline string[]? pre-review content for an atomic file decision
---@field failures table[]? per-part failures: { reason = string, at = number }

---@class Hunk
---@field id string
---@field description string
---@field old_start number
---@field old_lines number
---@field new_start number
---@field new_lines number
---@field lines string[]
---@field status Status
---@field modified_content string|nil

---Get the review record for `path`, or nil if not under review.
---@param path string
---@return Review|nil
function M.get_review(path)
	return M.reviews[path]
end

---The triage status for `hunk_id` in `path`: a live review is authoritative,
---otherwise the description restored by session.load. nil means pending.
---@param path string
---@param hunk_id string
---@return string|nil
function M.hunk_status(path, hunk_id)
	local review = M.reviews[path]
	if review then
		return review.hunk_status and review.hunk_status[hunk_id] or nil
	end
	local triage = M.triage[path]
	return triage and triage.hunk_status and triage.hunk_status[hunk_id] or nil
end

---True when `path` was hand-edited during review: live review first, then the
---restored description.
---@param path string
---@return boolean
function M.review_modified(path)
	local review = M.reviews[path]
	if review then
		return review.user_modified == true
	end
	local triage = M.triage[path]
	return triage ~= nil and triage.user_modified == true
end

---Store/replace the review record for `path`
---@param path string
---@param review Review
function M.set_review(path, review)
	M.reviews[path] = review
end

---Clear the review record for `path`.
---@param path string
function M.clear_review(path)
	M.reviews[path] = nil
end

-- Set a callback for when state changes
---@param callback function
function M.set_on_change(callback)
	M._on_change = callback
end

---Notify that state changed
function M.notify_change()
	if M._on_change then
		M._on_change()
	end
end

-- Get all changes
function M.get_changes()
	return M.changes
end

-- Get current change
---@return Change|nil
function M.get_current_change()
	return M.changes[M.current_change_index]
end

-- Get index of current change
---@return number
function M.get_change_index()
	return M.current_change_index or 0
end

-- Select the next change
function M.next_change()
	if #M.changes == 0 then
		return
	end

	M.current_change_index = math.max((M.current_change_index + 1) % (#M.changes + 1), 1)

	local change = M.get_current_change()
	if change then
		M.current_change_id = change.id
	end

	if M._on_change then
		M._on_change()
	end
end

-- Select the previous change
function M.prev_change()
	if #M.changes == 0 then
		return
	end

	M.current_change_index = M.current_change_index - 1
	if M.current_change_index <= 0 then
		M.current_change_index = #M.changes
	end

	local change = M.get_current_change()
	if change then
		M.current_change_id = change.id
	end

	if M._on_change then
		M._on_change()
	end
end

-- Returns whether a file's hunks are expanded
---@param file_path string
---@return boolean
function M.is_expanded(file_path)
	local change = M.get_current_change()
	if not change then
		return false
	end

	local change_expanded = M.expanded_files[change.id] or {}
	return change_expanded[file_path] or false
end

-- Toggles whether a file's hunks should be expanded
---@param file_path string
function M.toggle_file(file_path)
	local change = M.get_current_change()
	if not change then
		return
	end

	if not M.expanded_files[change.id] then
		M.expanded_files[change.id] = {}
	end

	local current = M.expanded_files[change.id][file_path] or false
	M.expanded_files[change.id][file_path] = not current

	if M._on_change then
		M._on_change()
	end
end

---Find a change's 1-based position by id.
---@param id string
---@return number|nil
local function change_index(id)
	for i, change in ipairs(M.changes) do
		if change.id == id then
			return i
		end
	end
	return nil
end

---Build a decision log entry for a completed change.
---Captures: id, title, timestamp, derived status, and per-file outcomes.
---@param change Change
---@return table entry
function M.build_log_entry(change)
	local entry = {
		id = change.id,
		title = change.title,
		timestamp = os.time(),
		status = M.derive_status(change),
		files = {},
	}

	for _, file in ipairs(change.files or {}) do
		local fentry = {
			path = file.path,
			status = file.status,
		}
		if file.failures and #file.failures > 0 then
			fentry.failures = vim.deepcopy(file.failures)
		end
		if file.status == "added" or file.status == "deleted" then
			fentry.decision = file.decision
		else
			fentry.modified = M.review_modified(file.path) or nil
			fentry.hunks = {}
			for _, hunk in ipairs(file.hunks or {}) do
				fentry.hunks[#fentry.hunks + 1] = {
					id = hunk.id,
					status = M.hunk_status(file.path, hunk.id),
				}
			end
		end
		entry.files[#entry.files + 1] = fentry
	end
	return entry
end

---Read-only, detached outcome snapshot for a change in this editor session.
---`under_review` tracks lifecycle membership, not whether a buffer is open or
---all hunks are triaged.
---@param id string
---@return table|nil
function M.get_change_status(id)
	local idx = change_index(id)
	local completed = M.completed[id]
	local entry = idx and M.build_log_entry(M.changes[idx]) or completed and completed.entry
	if not entry then
		return nil
	end
	return M.format_status(entry, idx ~= nil)
end

---Turn a decision-log entry into the wire `status` shape. Shared by the live,
---retained and persisted lookups so all three report identically.
---@param entry table
---@param under_review boolean
---@return table
function M.format_status(entry, under_review)
	local result = {
		id = entry.id,
		status = entry.status,
		under_review = under_review == true,
		files = vim.deepcopy(entry.files or {}),
	}
	for _, file in ipairs(result.files) do
		file.failures = file.failures or nil
		if file.status == "added" or file.status == "deleted" then
			file.decision = file.decision or "pending"
		else
			file.modified = file.modified == true
			for _, hunk in ipairs(file.hunks or {}) do
				hunk.status = hunk.status or "pending"
			end
		end
	end
	return result
end

M.log_file = nil
M._log_cache = nil
M._log_cache_file = nil
M._log_cache_size = nil
M._log_cache_mtime = nil

---Read the `id` of a decision-log entry, or nil when the entry is unusable.
---@param entry any
---@return string|nil
local function log_entry_id(entry)
	if type(entry) == "table" and type(entry.id) == "string" and #entry.id > 0 then
		return entry.id
	end
	return nil
end

---Decode the raw log text into entries. Handles both the current JSONL shape
---(one entry per line) and a legacy whole-file JSON array; a file where a
---legacy array is followed by JSONL lines yields entries from both. A line
---that is corrupt, truncated or missing a usable id is skipped.
---@param raw string
---@return table[] entries
---@return boolean migrate true when the file should be rewritten as JSONL
local function decode_log(raw)
	local trimmed = raw:gsub("^%s+", "")

	-- Legacy whole-file array: only when the entire file parses as one array.
	if trimmed:sub(1, 1) == "[" then
		local ok, decoded = pcall(vim.json.decode, raw)
		if ok and type(decoded) == "table" then
			local out = {}
			for _, entry in ipairs(decoded) do
				if log_entry_id(entry) then
					out[#out + 1] = entry
				end
			end
			return out, true
		end
		-- A whole-file decode failure falls through to per-line parsing so that
		-- whatever is recoverable is recovered.
	end

	local out = {}
	for line in raw:gmatch("[^\n]+") do
		if line:find("%S") then
			local trimmed_line = line:gsub("^%s+", "")
			local ok, decoded = pcall(vim.json.decode, line)
			if ok and type(decoded) == "table" then
				if trimmed_line:sub(1, 1) == "[" then
					-- A legacy array on its own line: take every entry it holds.
					for _, entry in ipairs(decoded) do
						if log_entry_id(entry) then
							out[#out + 1] = entry
						end
					end
				elseif log_entry_id(decoded) then
					out[#out + 1] = decoded
				end
			end
		end
	end
	-- Migrate only when the file is not JSONL yet and yielded entries: a file
	-- that cannot be parsed at all is left untouched.
	local needs_migration = trimmed:sub(1, 1) == "[" and #out > 0
	return out, needs_migration
end

---The file's identity, for cache validation.
---@return table|nil
local function log_file_identity(path)
	local st = vim.uv.fs_stat(path)
	if not st then
		return nil
	end
	return { size = st.size, mtime = st.mtime and st.mtime.nsec or nil }
end

---Write `entries` as JSONL, replacing the file atomically via a temp file so a
---crash cannot leave a half-written log.
---@param path string
---@param entries table[]
---@return boolean ok
local function write_log_lines(path, entries)
	local dir = vim.fn.fnamemodify(path, ":h")
	local ok = pcall(vim.fn.mkdir, dir, "p")
	if not ok then
		return false
	end
	local tmp = path .. ".tmp"
	local wrote = pcall(function()
		local out = assert(io.open(tmp, "w"))
		for _, entry in ipairs(entries) do
			out:write(vim.json.encode(entry), "\n")
		end
		out:close()
	end)
	if not wrote then
		pcall(os.remove, tmp)
		return false
	end
	local renamed = os.rename(tmp, path)
	if not renamed then
		pcall(os.remove, tmp)
		return false
	end
	return true
end

---Read every decision-log entry from disk, oldest first. Served from a cache
---validated against the file's identity, so repeated `status`/`list` calls do
---not re-read and re-decode the whole log.
---@return table[] entries (a copy: callers may mutate freely)
function M.read_log_file()
	return vim.deepcopy(M._read_log_raw())
end

---The cached entries themselves, without the protective copy. For internal
---read-only consumers (`_summarize_changes`, `get_persisted_status`), which
---build fresh tables and must never mutate what they scan.
---@return table[] entries (the live cache: do not mutate)
function M._read_log_raw()
	if not M.log_file then
		return {}
	end
	local path = M.log_file
	local identity = log_file_identity(path)
	local fresh_cache = M._log_cache
		and M._log_cache_file == path
		and (
			(identity == nil and M._log_cache_size == nil)
			or (identity ~= nil and M._log_cache_size == identity.size and M._log_cache_mtime == identity.mtime)
		)
	if fresh_cache then
		return M._log_cache
	end

	local f = io.open(path, "r")
	if not f then
		M._log_cache, M._log_cache_file = {}, path
		M._log_cache_size, M._log_cache_mtime = nil, nil
		return M._log_cache
	end
	local raw = f:read("*a")
	f:close()

	local entries, needs_migration = decode_log(raw)
	if needs_migration then
		if not write_log_lines(path, entries) then
			pcall(
				vim.notify,
				"CodeForge: could not migrate the decision log to JSONL; leaving it as-is",
				vim.log.levels.WARN
			)
		end
	end
	local fresh = log_file_identity(path)
	M._log_cache, M._log_cache_file = entries, path
	M._log_cache_size = fresh and fresh.size or (identity and identity.size) or nil
	M._log_cache_mtime = fresh and fresh.mtime or (identity and identity.mtime) or nil
	return M._log_cache
end

---Drop the cached log (a write, a `log_file` change, or a test reset).
function M.invalidate_log_cache()
	M._log_cache = nil
	M._log_cache_file = nil
	M._log_cache_size = nil
	M._log_cache_mtime = nil
end

---Ordering key for a change summary: newest first, ties broken by id so the
---order is total and stable (pagination depends on it).
---@param a table
---@param b table
---@return boolean
local function newer_first(a, b)
	local at, bt = a.timestamp or 0, b.timestamp or 0
	if at ~= bt then
		return at > bt
	end
	return a.id > b.id
end

---Every change this editor can describe: tracked now, completed this session,
---and completed in earlier sessions (read from the decision log). Deduped by
---id; live state wins over a retained completion, which wins over the log.
---`status` carries real outcomes only, so a later `reopened` marker never
---replaces the outcome it followed.
---@return table[] sorted newest-first
function M.known_changes()
	return M._summarize_changes(M._read_log_raw())
end

---Build the summary list from an already-decoded log.
---@param log_entries table[]
---@return table[] sorted newest-first
function M._summarize_changes(log_entries)
	local by_id = {}

	-- Ascending precedence: each source overwrites the previous one.
	local function record(summary)
		by_id[summary.id] = summary
	end

	-- Keep the newest real outcome per id; a `reopened` marker is not an outcome.
	for _, entry in ipairs(log_entries) do
		if entry.status ~= "reopened" then
			local seen = by_id[entry.id]
			if not seen or (entry.timestamp or 0) >= (seen.timestamp or 0) then
				record({
					id = entry.id,
					title = entry.title or entry.id,
					timestamp = entry.timestamp or 0,
					status = entry.status,
					under_review = false,
				})
			end
		end
	end
	for _, entry in ipairs(M.log) do
		if entry.status ~= "reopened" then
			record({
				id = entry.id,
				title = entry.title or entry.id,
				timestamp = entry.timestamp or 0,
				status = entry.status,
				under_review = false,
			})
		end
	end
	for id, completed in pairs(M.completed) do
		local entry = completed.entry or {}
		record({
			id = id,
			title = (completed.change and completed.change.title) or entry.title or id,
			timestamp = entry.timestamp or 0,
			status = entry.status,
			under_review = false,
		})
	end
	for _, change in ipairs(M.changes) do
		record({
			id = change.id,
			title = change.title or change.id,
			timestamp = change.timestamp or 0,
			status = M.derive_status(change),
			under_review = true,
		})
	end

	local summaries = {}
	for _, summary in pairs(by_id) do
		summaries[#summaries + 1] = summary
	end
	table.sort(summaries, newer_first)
	return summaries
end

---A change's outcome from the persisted decision log, for a change this
---session did not see. `nil` when no outcome was ever recorded.
---@param id string
---@return table|nil
function M.get_persisted_status(id)
	local newest
	for _, entry in ipairs(M._read_log_raw()) do
		if entry.id == id and entry.status ~= "reopened" then
			if not newest or (entry.timestamp or 0) >= (newest.timestamp or 0) then
				newest = entry
			end
		end
	end
	if not newest then
		return nil
	end
	return M.format_status(newest, false)
end

---Append an entry to the in-memory decision log (and the on-disk log file).
---@param entry table
function M.append_log(entry)
	table.insert(M.log, entry)
	M.persist_log(entry)
end

---Append `entry` to `M.log_file` as one JSONL line, without reading the
---existing file.
---@param entry table
function M.persist_log(entry)
	if not M.log_file then
		return
	end
	local path = M.log_file
	local ok, err = pcall(function()
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		local out = assert(io.open(path, "a"))
		out:write(vim.json.encode(entry), "\n")
		out:close()
	end)
	M.invalidate_log_cache()
	if not ok then
		pcall(vim.notify, "CodeForge: failed to persist decision log: " .. tostring(err), vim.log.levels.WARN)
	end
end

---Find the tracked change containing `path`, or nil.
---@param path string
---@return Change|nil
function M.change_for_path(path)
	for _, change in ipairs(M.changes) do
		for _, file in ipairs(change.files or {}) do
			if file.path == path then
				return change
			end
		end
	end
	return nil
end

---Find the tracked file entry for `change_id`/`path`, or nil.
---@param change_id string
---@param path string
---@return File|nil
function M.file_for(change_id, path)
	for _, change in ipairs(M.changes) do
		if change.id == change_id then
			for _, file in ipairs(change.files or {}) do
				if file.path == path then
					return file
				end
			end
		end
	end
	return nil
end

---Mark one part (file) of a change as failed to review or apply. The part and
---its triage are preserved. Re-marking the same reason refreshes its timestamp
---instead of stacking duplicates.
---@param change_id string
---@param path string
---@param reason string
---@return boolean marked false when the change/file is not tracked
function M.mark_file_failed(change_id, path, reason)
	local file = M.file_for(change_id, path)
	if not file or type(reason) ~= "string" or #reason == 0 then
		return false
	end
	file.failures = file.failures or {}
	for _, failure in ipairs(file.failures) do
		if failure.reason == reason then
			failure.at = os.time()
			M.notify_change()
			return true
		end
	end
	file.failures[#file.failures + 1] = { reason = reason, at = os.time() }
	M.notify_change()
	return true
end

---Clear one recorded failure for `file` by reason.
---@param file File
---@param reason string
---@return boolean cleared
function M.clear_file_failure(file, reason)
	if type(file) ~= "table" or type(file.failures) ~= "table" then
		return false
	end
	for i, failure in ipairs(file.failures) do
		if failure.reason == reason then
			table.remove(file.failures, i)
			if #file.failures == 0 then
				file.failures = nil
			end
			M.notify_change()
			return true
		end
	end
	return false
end

---Preflight completion for `change`: refuse when any open review's final
---assembly is unsafe (conflicting gap edits). Read-only.
---@param change Change
---@return boolean ok
---@return string|nil message
function M.preflight_complete(change)
	if not change then
		return true
	end
	for _, file in ipairs(change.files or {}) do
		local review = M.reviews[file.path]
		if review then
			local ok, msg = review:preflight()
			if not ok then
				return false, ("%s: %s"):format(file.path, msg)
			end
		end
	end
	return true
end

---Complete a fully-triaged change. Refuses (returns false, logs nothing,
---keeps reviews and the change tracked) when any file's final assembly is
---unsafe.
---@param change Change
---@return boolean completed
function M.complete_change(change)
	if not change then
		return false
	end

	local ok, msg = M.preflight_complete(change)
	if not ok then
		vim.notify("CodeForge: cannot finish: " .. msg, vim.log.levels.WARN)
		return false
	end

	local entry = M.build_log_entry(change)
	local reviews = {}
	for _, file in ipairs(change.files or {}) do
		local review = M.reviews[file.path]
		if review then
			reviews[file.path] = review
			review:dismiss()
		end
	end
	M.completed[change.id] = { change = change, reviews = reviews, entry = entry }
	M.completed_order[#M.completed_order + 1] = change.id
	M.remove_change(change.id, entry)
	return true
end

---Revive a completed change by id
---@param id string
---@return boolean revived
function M.revive_change(id)
	local completed = M.completed[id]
	if not completed then
		return false
	end
	M.completed[id] = nil
	for i, cid in ipairs(M.completed_order) do
		if cid == id then
			table.remove(M.completed_order, i)
			break
		end
	end
	local change = completed.change
	table.insert(M.changes, change)
	if M.current_change_index == nil then
		M.current_change_index = #M.changes
		M.current_change_id = change.id
	end
	for _, review in pairs(completed.reviews) do
		review:revive()
	end
	M.append_log({
		id = change.id,
		title = change.title,
		timestamp = os.time(),
		status = "reopened",
	})
	M.notify_change()
	return true
end

---Reopen a completed change as a fresh review round.
---@param id string
---@return boolean reopened
function M.reopen_change(id)
	local completed = M.completed[id]
	if not completed then
		return false
	end
	M.completed[id] = nil
	for i, cid in ipairs(M.completed_order) do
		if cid == id then
			table.remove(M.completed_order, i)
			break
		end
	end
	local change = completed.change
	for _, file in ipairs(change.files or {}) do
		file.decision = nil
		-- The previous final content is the new `U`, so the atomic baseline must
		-- be re-captured rather than reused.
		file.atomic_baseline = nil
	end
	table.insert(M.changes, change)
	M.current_change_index = #M.changes
	M.current_change_id = change.id
	require("codeforge.history").purge_change(id)
	M.append_log({
		id = change.id,
		title = change.title,
		timestamp = os.time(),
		status = "reopened",
	})
	M.notify_change()
	return true
end

---Watch for completion: when `change`'s derived status has left `pending`,
---complete it. Returns false when the change is still pending or when
---completion is refused.
---@param change Change
---@return boolean completed
function M.maybe_complete(change)
	if not change or not change.id then
		return false
	end

	for _, c in ipairs(M.changes) do
		if c == change then
			if M.derive_status(change) == "pending" then
				return false
			end
			return M.complete_change(change)
		end
	end
	return false
end

---Remove the change with `id` from the change list.
---@param id string
---@param entry table?
---@return boolean removed true when a change with `id` existed
function M.remove_change(id, entry)
	local idx = change_index(id)
	if not idx then
		return false
	end

	local change = M.changes[idx]
	M.append_log(entry or M.build_log_entry(change))
	table.remove(M.changes, idx)
	M.expanded_files[id] = nil

	if M.current_change_index ~= nil then
		if idx < M.current_change_index then
			M.current_change_index = M.current_change_index - 1
		elseif idx == M.current_change_index then
			M.current_change_index = math.min(M.current_change_index, #M.changes)
			if #M.changes == 0 then
				M.current_change_index = nil
			end
		end

		local current = M.get_current_change()
		M.current_change_id = current and current.id or nil
	end

	M.notify_change()
	return true
end

---True when `file` needs no hunk-level review: a whole-file addition
---or a whole-file deletion.
---@param file File
---@return boolean
local function is_atomic(file)
	return file.status == "added" or file.status == "deleted"
end

---True when every part of `file` has been triaged.
---@param file File
---@return boolean
function M.file_completed(file)
	if is_atomic(file) then
		return file.decision ~= nil
	end

	for _, hunk in ipairs(file.hunks or {}) do
		local st = M.hunk_status(file.path, hunk.id)
		if st ~= "accepted" and st ~= "rejected" then
			return false
		end
	end
	return true
end

---Completion indicator for a sidebar file row: the hunk-review
---glyph for modified files, the file-level decision for added/
---deleted files.
---@param file File
---@return string glyph "●" completed | "○" pending
---@return string hl_group
function M.file_status_glyph(file)
	local hl = require("codeforge.highlight")
	if file.failures and #file.failures > 0 then
		return "⚠", "CodeForgeReviewFailed"
	end
	if not M.file_completed(file) then
		return "○", hl.get_review_status_hl(nil)
	end
	if is_atomic(file) then
		return "●", hl.get_review_status_hl(file.decision)
	end
	local all_accepted = true
	for _, hunk in ipairs(file.hunks or {}) do
		if M.hunk_status(file.path, hunk.id) ~= "accepted" then
			all_accepted = false
			break
		end
	end
	return "●", hl.get_review_status_hl(all_accepted and "accepted" or "modified")
end

---Derive a change's aggregate review status from its child hunks.
---  pending  -> any hunk still pending
---  accepted -> all hunks accepted
---  rejected -> all hunks rejected
---  modified -> mixed accept/reject, or edited
---@param change Change
---@return "pending"|"accepted"|"rejected"|"modified"
function M.derive_status(change)
	local any_pending = false
	local any_accepted = false
	local any_rejected = false
	local user_modified = false
	local any_failed = false

	for _, file in ipairs(change.files or {}) do
		if M.review_modified(file.path) then
			user_modified = true
		end
		if file.failures and #file.failures > 0 then
			any_failed = true
		end
		if is_atomic(file) then
			if file.decision == "accepted" then
				any_accepted = true
			elseif file.decision == "rejected" then
				any_rejected = true
			else
				any_pending = true
			end
		else
			for _, hunk in ipairs(file.hunks or {}) do
				local st = M.hunk_status(file.path, hunk.id)
				if st == "accepted" then
					any_accepted = true
				elseif st == "rejected" then
					any_rejected = true
				else
					any_pending = true
				end
			end
		end
	end

	if any_pending then
		return "pending"
	end
	if user_modified or any_failed or (any_accepted and any_rejected) then
		return "modified"
	end
	if any_rejected then
		return "rejected"
	end
	return "accepted"
end

return M
