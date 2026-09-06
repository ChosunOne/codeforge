local state = require("codeforge.state")
local diff = require("codeforge.review.diff")
local merge = require("codeforge.review.merge")

---@class ResolveState
---@field hunk_id string
---@field first integer 0-indexed live buffer region start
---@field last integer 0-indexed live buffer end (inclusive)
---@field region_len_integer integer number of buffer lines the conflict region occupies
---@field resolve_buf integer the editable conflict buffer
---@field resolve_win integer window showing the resolve_buf
---@field proposal_R string[] the proposal side P'[R], for <C-x>p take-proposal
---@field block_mark integer extmark id tracking the current conflict block's start row in resolve_buf

---@class Review
---@field path string
---@field buf integer the file buffer under review
---@field base_content string[] what the AI diffed against
---@field buf_snapshot string[] the user's pre-review buffer content
---@field hunks Hunk[] hunks for this file
---@field placements Placement[] per-hunk placement plan
---@field extmark_ids integer[] extmark ids created by the render
---@field expanded table<string, boolean> hunk_id -> expanded
---@field hunk_status table<string, string> hunk_id -> 'pending|'rejected'|'accepted'
---@field proposal string[]? unmodified proposal P
---@field user_modified boolean true when the user edited the buffer during review
---@field _reconcile_timer any? debounce timer for the edit reconciler
local Review = {}
Review.__index = Review

---The window showing `buf` or nil.
---@param buf integer
---@return integer|nil
local function win_for_buf(buf)
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) == buf then
			return w
		end
	end
	return nil
end

---Build the virt_lines blcok for a `fold` given its expanded state.
---Collapsed: the "- N line(s) removed" hint. Expanded: one virt line
---per deleted line, each styled with `CodeForgeHunkDeleted`.
---@param fold Fold
---@param expanded boolean
---@return table virt_lines
local function fold_virt_lines(fold, expanded)
	if expanded then
		local lines = {}
		for _, l in ipairs(fold.lines) do
			lines[#lines + 1] = { { l, "CodeForgeHunkDeleted" } }
		end
		return lines
	end
	local text = string.format("- %d %s removed", fold.count, fold.count == 1 and "line" or "lines")
	return { { { text, "CodeForgeHunkDeleted" } } }
end

---Scan [lo, hi] (0-indexed, inclusive) for the first complete merge-conflict
---block. Returns 0-indexed inclusive start/end, or nil.
---@param lines string[]
---@param lo integer 0-indexed start (inclusive)
---@param hi integer 0-indexed end (inclusive)
---@return integer? block_start 0-indexed inclusive
---@return integer? block_end 0-indexed inclusive
local function scan_block(lines, lo, hi)
	local s, e
	for i = lo + 1, hi + 1 do
		local l = lines[i]
		if not l then
			break
		end
		if l:sub(1, 7) == "<<<<<<<" then
			s = i - 1
		elseif l:sub(1, 7) == ">>>>>>>" and s then
			e = i - 1
			break
		end
	end
	return s, e
end

---Find the merge-conflict block belonging to the hunk under resolve,
---scoped to that hunk's region [scope_lo, scope_hi] (0-indexed, inclusive).
---Falls back to a whole-buffer scan only when no complete block exists in
---the window. Returns 0-indexed inclusive start/end, or nil.
---@param lines string[]
---@param scope_lo integer 0-indexed region start (inclusive)
---@param scope_hi integer 0-indexed region end (inclusive)
---@param track_row integer 0-indexed last known position of the block's start
---@return integer? block_start 0-indexed inclusive
---@return integer? block_end 0-indexed inclusive
local function find_conflict_block(lines, scope_lo, scope_hi, track_row)
	local opener = lines[track_row + 1]
	if opener and opener:sub(1, 7) == "<<<<<<<" then
		local _, e = scan_block(lines, track_row, #lines - 1)
		if e then
			return track_row, e
		end
	end
	return scan_block(lines, scope_lo, scope_hi)
end

---Placement rows are represented by extmark ids. Use `_row_of` to
---get the row of the placement.
---@class Placement
---@field hunk_id string
---@field adds integer[]? rows of the hunk's new lines (added+modified+context)
---@field kinds string[]? per adds[i]: "added"|"modified"|"context"
---@field add_contents string[]? the text of each adds[i] line, for deletion detection
---@field sign_marks integer[]? extmark id per signed adds[i] line
---@field fold Fold?
---@field fold_mark integer? extmark id anchoring the fold's sign/virt_lines
---@field region_mark integer? extmark id anchoring a resolved hunk's region
---@field region_len integer? number of buffer lines in the resolved region
---@field region_row integer? the resolved region's 0-indexed start row
---@field region_start integer 1-indexed start of the hunk's region in O
---@field region_count integer number of O lines in the hunk's region

---@class Fold
---@field anchor_row integer
---@field count integer
---@field lines string[]

---Construct a `Review` for `path` backed by `buf`, with base `base`
---@param path string
---@param buf integer
---@param base string[]
---@param hunks Hunk[]
---@return Review
function Review.new(path, buf, base, hunks)
	return setmetatable({
		path = path,
		buf = buf,
		base_content = base,
		buf_snapshot = {},
		hunks = hunks or {},
		placements = {},
		extmark_ids = {},
		expanded = {},
		hunk_status = {},
		user_modified = false,
		_machine_tick = nil,
	}, Review)
end

---Walk the hunks in order, set the buffer to the proposal, and
---record the placement plan on `self.placements`
---@param self Review
function Review:apply_hunks()
	local base = self.base_content
	local sorted = {} ---@type Hunk[]
	for _, h in ipairs(self.hunks) do
		sorted[#sorted + 1] = h
	end
	table.sort(sorted, function(a, b)
		return a.old_start < b.old_start
	end)

	local out = {} ---@type string[]
	local placements = {} ---@type Placement[]
	local cursor = 1 -- 1-indexed next base line to copy
	for _, h in ipairs(sorted) do
		local start = h.old_start -- 1-indexed
		while cursor < start do
			out[#out + 1] = base[cursor]
			cursor = cursor + 1
		end

		local removed = 0
		local removed_lines = {} ---@type string[]
		for _, line in ipairs(h.lines) do
			if line:sub(1, 1) == "-" then
				removed = removed + 1
				removed_lines[#removed_lines + 1] = line:sub(2)
			end
		end

		local new_lines = {} ---@type string[]
		local adds = {} ---@type integer[]
		for _, line in ipairs(h.lines) do
			local prefix = line:sub(1, 1)
			if prefix == "+" or prefix == " " then
				local content = line:sub(2)
				out[#out + 1] = content
				new_lines[#new_lines + 1] = content
				if prefix == "+" then
					adds[#adds + 1] = #out - 1
				end
			end
		end

		local kinds ---@type string[]?
		if #new_lines > 0 then
			if removed > 0 then
				kinds = merge.classify_modify(removed_lines, new_lines)
			else
				kinds = {}
				for _ = 1, #new_lines do
					kinds[#kinds + 1] = "added"
				end
			end
		end

		local fold ---@type Fold?
		if removed > 0 and #new_lines == 0 then
			local anchor_row = #out - 1 -- 0-indexed last written proposal line
			if anchor_row < 0 then
				anchor_row = 0
			end
			fold = { anchor_row = anchor_row, count = removed, lines = removed_lines }
		end

		cursor = cursor + h.old_lines

		placements[#placements + 1] = {
			hunk_id = h.id,
			adds = adds,
			kinds = kinds,
			add_contents = #new_lines > 0 and new_lines or nil,
			fold = fold,
			region_start = h.old_start,
			region_count = h.old_lines,
		}
	end

	while cursor <= #base do
		out[#out + 1] = base[cursor]
		cursor = cursor + 1
	end

	self.placements = placements
	self.proposal = out
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, out)
	self._machine_tick = vim.api.nvim_buf_get_changedtick(self.buf)
end

---Stores each extmark's id back on the placement so the live row can be
---derived later via `_row_of`. Each sign is given a range spanning its
---line content so in-line edits keep the sign on the line and insertions
---above shift it down with the content.
---@param self Review
function Review:render()
	local ns = diff.namespace

	for _, p in ipairs(self.placements) do
		if p.fold and p.fold_mark then
			local r = self:_row_of(p.fold_mark)
			if r ~= nil then
				p.fold.anchor_row = r
			end
		end
		for i, mark in ipairs(p.sign_marks or {}) do
			if mark then
				local r = self:_row_of(mark)
				if r ~= nil and p.adds then
					p.adds[i] = r
				end
			end
		end

		if p.region_mark then
			p.region_row = self:_row_of(p.region_mark)
		end
	end

	vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
	self.extmark_ids = {}

	for _, p in ipairs(self.placements) do
		if p.region_mark and p.region_len then
			local r = p.region_row
			if r ~= nil then
				p.region_mark = vim.api.nvim_buf_set_extmark(self.buf, ns, r, 0, {
					end_row = r + p.region_len - 1,
					right_gravity = false,
					end_right_gravity = true,
				})
			else
				p.region_mark = nil
			end
		end

		if p.fold then
			local expanded = self.expanded[p.hunk_id] == true
			local id = vim.api.nvim_buf_set_extmark(self.buf, ns, p.fold.anchor_row, 0, {
				virt_lines = fold_virt_lines(p.fold, expanded),
				sign_text = "-",
				sign_hl_group = "CodeForgeHunkDeleted",
			})
			self.extmark_ids[#self.extmark_ids + 1] = id
			p.fold_mark = id
		end

		p.sign_marks = {}
		for i, row in ipairs(p.adds or {}) do
			local kind = p.kinds and p.kinds[i] or "added"
			if row == false then
				-- skip
			elseif kind == "context" then
				p.sign_marks[i] = vim.api.nvim_buf_set_extmark(self.buf, ns, row, 0, { end_row = row })
			else
				local hl = kind == "modified" and "CodeForgeHunkModified" or "CodeForgeHunkAdded"
				local sign = kind == "modified" and "~" or "+"
				local id = vim.api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
					end_row = row,
					hl_group = hl,
					sign_text = sign,
					sign_hl_group = hl,
				})
				self.extmark_ids[#self.extmark_ids + 1] = id
				p.sign_marks[i] = id
			end
		end
	end
end

---The live 0-indexed row of extmark `id`, or nil if the mark is gone.
---This is the single source of truth for a placement's position.
---@param self Review
---@param id integer?
---@return integer? row 0-indexed
function Review:_row_of(id)
	if not id then
		return nil
	end
	local pos = vim.api.nvim_buf_get_extmark_by_id(self.buf, diff.namespace, id, {})
	if not pos or #pos == 0 then
		return nil
	end
	return pos[1]
end

---Toggle the deletion fold anchored at buffer row `row` (0-indexed)
---between collapsed (hint) and expanded (deleted lines). No-op if no fold is
---anchored at `row`.
---@param self Review
---@param row integer 0-indexed buffer row
function Review:toggle_fold(row)
	for _, p in ipairs(self.placements) do
		if p.fold and self:_row_of(p.fold_mark) == row then
			self.expanded[p.hunk_id] = not (self.expanded[p.hunk_id] == true)
			self:render()
			return
		end
	end
end

---Restore the deletion fold anchored at buffer row `row` (0-indexed)
---Promote the deleted lines to real buffer text at that position and drop the fold.
---No-op if no fold is anchored at `row`.
---@param self Review
---@param row integer 0-indexed buffer row
function Review:restore_fold(row)
	for _, p in ipairs(self.placements) do
		local anchor = self:_row_of(p.fold_mark)
		if p.fold and anchor == row then
			local lines = p.fold.lines
			vim.api.nvim_buf_set_lines(self.buf, row + 1, row + 1, false, lines)
			self._machine_tick = vim.api.nvim_buf_get_changedtick(self.buf)
			p.adds = {}
			p.kinds = {}
			p.add_contents = {}
			for k = 1, #lines do
				p.adds[k] = row + k
				p.kinds[k] = "context"
				p.add_contents[k] = lines[k]
			end
			p.fold = nil
			p.fold_mark = nil
			self.expanded[p.hunk_id] = nil
			self:render()
			return
		end
	end
end

---Find the placement whose hunk covers buffer `row` (0-indexed): either an added
---line of the hunk or its deletion fold anchor.
---@param self Review
---@param row integer 0-indexed buffer row
---@return Placement? placement
function Review:hunk_at_row(row)
	for _, p in ipairs(self.placements) do
		if p.fold and self:_row_of(p.fold_mark) == row then
			return p
		end
		for _, mark in ipairs(p.sign_marks or {}) do
			if self:_row_of(mark) == row then
				return p
			end
		end
		local rstart = self:_row_of(p.region_mark)
		if rstart ~= nil and row >= rstart and row < rstart + (p.region_len or 1) then
			return p
		end
	end
	return nil
end

---The live anchor row (0-indexed) of a placement's hunk: its deletion fold if it
---has one, else its first added line.
---@param self Review
---@param p Placement
---@return integer?
function Review:_hunk_anchor(p)
	if p.fold_mark then
		return self:_row_of(p.fold_mark)
	end
	for _, mark in ipairs(p.sign_marks or {}) do
		local r = self:_row_of(mark)
		if r ~= nil then
			return r
		end
	end
	return self:_row_of(p.region_mark)
end

---The live buffer region [first, last] (0-indexed, inclusive) covered by a
---placement. For a deletion fold this is the empty range [anchor + 1, anchor];
---for added/modified lines it spans the first to the last signed line.
---Returns nil when nothing is placed.
---@param self Review
---@param p Placement
---@return integer? first 0-indexed inclusive
---@return integer? last 0-indexed inclusive
function Review:_region_rows(p)
	local anchor = self:_row_of(p.fold_mark)
	if anchor ~= nil then
		return anchor + 1, anchor
	end
	local first, last
	for _, mark in ipairs(p.sign_marks or {}) do
		local r = self:_row_of(mark)
		if r ~= nil then
			if not first or r < first then
				first = r
			end
			if not last or r > last then
				last = r
			end
		end
	end

	if first then
		return first, last
	end
	local rstart = self:_row_of(p.region_mark)
	if rstart ~= nil then
		return rstart, rstart + (p.region_len or 1) - 1
	end
	return nil, nil
end

---Return the 1-indexed buffer line of hunk `hunk_id`'s anchor
---or nil if the hunk isn't placed
---@param self Review
---@param hunk_id string
---@return integer? line 1-indexed
function Review:hunk_row(hunk_id)
	for _, p in ipairs(self.placements) do
		if p.hunk_id == hunk_id then
			local a = self:_hunk_anchor(p)
			if a ~= nil then
				return a + 1
			end
			return nil
		end
	end
	return nil
end

---The list of placements whose hunk is still pending in buffer order.
---@param self Review
---@return Placement[]
function Review:pending_hunks()
	local out = {}
	for _, p in ipairs(self.placements) do
		local st = self.hunk_status[p.hunk_id]
		if st ~= "accepted" and st ~= "rejected" then
			out[#out + 1] = p
		end
	end

	return out
end

---Move the cursor to the next pending hunk's anchor (wraps to the first).
---@param self Review
function Review:next_hunk()
	local pending = self:pending_hunks()
	if #pending == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
	local best = nil
	for _, p in ipairs(pending) do
		local a = self:_hunk_anchor(p)
		if a ~= nil and a > cur then
			best = a
			break
		end
	end
	if best == nil then
		best = self:_hunk_anchor(pending[1])
	end
	if best ~= nil then
		vim.api.nvim_win_set_cursor(0, { best + 1, 0 })
	end
end

---Move the cursor to the previous pending hunk's anchor (wraps to the last)
---@param self Review
function Review:prev_hunk()
	local pending = self:pending_hunks()
	if #pending == 0 then
		return
	end
	local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
	local cur_anchor = nil
	for _, p in ipairs(pending) do
		local a = self:_hunk_anchor(p)
		if a ~= nil and a <= cur then
			cur_anchor = a
		end
	end
	local best = nil
	for i = #pending, 1, -1 do
		local a = self:_hunk_anchor(pending[i])
		if a ~= nil and cur_anchor ~= nil and a < cur_anchor then
			best = a
			break
		end
	end
	if best == nil then
		best = self:_hunk_anchor(pending[#pending])
	end
	if best ~= nil then
		vim.api.nvim_win_set_cursor(0, { best + 1, 0 })
	end
end

---Record a hunk triage action into the undo history
---@param self Review
---@param p Placement
---@param before table { status?, region? }
---@param after table { status, region? }
function Review:_record_triage(p, before, after)
	local change = state.change_for_path(self.path)
	require("codeforge.history").record({
		kind = "hunk",
		change_id = change and change.id or nil,
		path = self.path,
		hunk_id = p.hunk_id,
		before = before,
		after = after,
	})
end

---Reject the hunk covering buffer `row`: drop the AI change for that hunk's
---region so the buffer reflects `U` there. For a pure-add hunk this removes
---the added lines; a deletion fold is restored as real text. Marks the hunk
---'rejected'. No-op if no hunk covers `row` or it is already rejected.
---@param self Review
---@param p Placement?
---@return boolean handled
function Review:_reject_placement(p)
	if not p or self.hunk_status[p.hunk_id] == "rejected" then
		return false
	end
	local adds = p.adds or {}
	local first = p.fold and p.fold.anchor_row + 1 or adds[1]
	local last = adds[#adds] or (p.fold and p.fold.anchor_row)
	local hist_before = { status = self.hunk_status[p.hunk_id] }
	if first then
		hist_before.region = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	end
	if not first then
		self.hunk_status[p.hunk_id] = "rejected"
		state.notify_change()
		self:_record_triage(p, hist_before, { status = "rejected" })
		return true
	end

	local replacement = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	self:_apply_region(p, first, last, replacement)
	self.hunk_status[p.hunk_id] = "rejected"
	self:render()
	state.notify_change()
	self:_record_triage(p, hist_before, { status = "rejected", region = replacement })
	return true
end

function Review:reject_hunk(row)
	self:_reject_placement(self:hunk_at_row(row))
	state.maybe_complete(state.change_for_path(self.path))
end

---@param self Review
---@param p Placement?
---@return boolean handled
function Review:_accept_placement(p)
	if not p or self.hunk_status[p.hunk_id] == "rejected" then
		return false
	end
	local first, last = self:_region_rows(p)
	local hist_before = { status = self.hunk_status[p.hunk_id] }
	if first then
		hist_before.region = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	end
	if not first then
		self.hunk_status[p.hunk_id] = "accepted"
		state.notify_change()
		self:_record_triage(p, hist_before, { status = "accepted" })
		return true
	end

	local ours = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	local base = merge.region_in(self.base_content, self.base_content, p.region_start, p.region_count)
	local cur = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	local res = merge.merge3(ours, base, cur)
	if res.conflict then
		self.hunk_status[p.hunk_id] = "conflicted"
		state.notify_change()
		self:_record_triage(p, hist_before, { status = "conflicted" })
		return true
	end
	self:_apply_region(p, first, last, res.lines)
	self.hunk_status[p.hunk_id] = "accepted"
	self:render()
	state.notify_change()
	self:_record_triage(p, hist_before, { status = "accepted", region = res.lines })
	return true
end

function Review:accept_hunk(row)
	self:_accept_placement(self:hunk_at_row(row))
	state.maybe_complete(state.change_for_path(self.path))
end

---Sweep `core` over every still-pending placement, in buffer order.
---Returns the number of hunks handled
---@param self Review
---@param core fun(self: Review, p: Placement): boolean
---@param include_conflicted boolean
---@return integer count
function Review:_sweep(core, include_conflicted)
	local pending = self:pending_hunks()
	local n = 0
	for _, p in ipairs(pending) do
		local st = self.hunk_status[p.hunk_id]
		if st == nil or (include_conflicted and st == "conflicted") then
			core(self, p)
			n = n + 1
		end
	end
	return n
end

---Accept every pending hunk in this review.
---Returns the number of hunks handled.
---@param self Review
---@return integer count
function Review:accept_pending()
	return self:_sweep(self._accept_placement, false)
end

---Reject every pending hunk in this review.
---@param self Review
---@return integer count
function Review:reject_pending()
	return self:_sweep(self._reject_placement, true)
end

---Enter single-buffer conflict resolution for the conflicted hunk covering `row`.
---Builds one editable buffer holding the full file P with a git merge-conflict
---block (<<<<<<< ours / ======= / >>>>>>> proposal) around the conflict region R,
---and install resolve keymaps (<C-x>o take ours, <C-x>p take proposal, <C-x>f
---confirm). Keymaps are installed before the buffer is shown so prefix-trigger
---plugins register <C-x> on BufEnter. No-op if the hunk is not conflicted.
---@param self Review
---@param row integer 0-indexed buffer row
function Review:resolve_hunk(row)
	local p = self:hunk_at_row(row)
	if not p or self.hunk_status[p.hunk_id] ~= "conflicted" then
		return
	end
	local first, last = self:_region_rows(p)
	if not first then
		return
	end

	if self._resolve and self._resolve.hunk_id == p.hunk_id then
		return
	end
	self:_close_resolve()

	local ours_R = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	local base_R = merge.region_in(self.base_content, self.base_content, p.region_start, p.region_count)
	local live_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false) -- full P
	local live_R = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false) -- P'[R]

	local ft = vim.bo[self.buf].filetype
	if ft == "" then
		ft = vim.filetype.match({ filename = self.path }) or ""
		if ft ~= "" then
			vim.bo[self.buf].filetype = ft
		end
	end

	local res = merge.merge3_named(ours_R, base_R, live_R, "ours", "proposal")
	local conflict_region = res.lines
	local conflict_lines = {}
	for i = 0, first - 1 do
		conflict_lines[#conflict_lines + 1] = live_lines[i + 1]
	end
	for _, l in ipairs(conflict_region) do
		conflict_lines[#conflict_lines + 1] = l
	end
	for i = last + 2, #live_lines do
		conflict_lines[#conflict_lines + 1] = live_lines[i]
	end

	local review_win = win_for_buf(self.buf) or self:_main_win()
	local b = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(b, "codeforge.resolve.live")
	vim.api.nvim_buf_set_lines(b, 0, -1, false, conflict_lines)
	if ft ~= "" then
		vim.bo[b].filetype = ft
	end
	vim.bo[b].modifiable = true
	vim.bo[b].bufhidden = "wipe"
	local resolve_win = review_win or vim.api.nvim_get_current_win()
	self._resolve = {
		hunk_id = p.hunk_id,
		first = first,
		last = last,
		region_len = #conflict_region,
		resolve_buf = b,
		resolve_win = resolve_win,
		review_win = review_win,
		proposal_R = live_R,
	}
	self:_setup_resolve_keymaps()
	if review_win then
		vim.api.nvim_win_set_buf(review_win, b)
	else
		vim.api.nvim_win_set_buf(0, b)
	end
	vim.wo[resolve_win].winbar = "RESOLVE (edit)  <C-x>o take ours  <C-x>p take proposal  <C-x>f confirm"
	vim.wo[resolve_win].signcolumn = "yes"

	local resolve_ns = vim.api.nvim_create_namespace("codeforge_resolve")
	local track_ns = vim.api.nvim_create_namespace("codeforge_resolve_track")
	local function locate(lines)
		return find_conflict_block(lines, first, first + #conflict_region - 1, self:_resolve_track_row())
	end

	local function paint(lines, bs, be)
		for row = bs, be do
			local line = lines[row + 1]
			local is_marker = line:sub(1, 7) == "<<<<<<<" or line:sub(1, 7) == "=======" or line:sub(1, 7) == ">>>>>>>"
			vim.api.nvim_buf_set_extmark(b, resolve_ns, row, 0, {
				sign_text = "!",
				sign_hl_group = "CodeForgeReviewConflicted",
				hl_group = is_marker and "CodeForgeReviewConflicted" or nil,
				end_row = row,
				end_col = is_marker and #line or 0,
				priority = 200,
			})
		end
	end

	local block_start, block_end = locate(conflict_lines)
	if block_start then
		self._resolve.block_mark = vim.api.nvim_buf_set_extmark(b, track_ns, block_start, 0, { right_gravity = false })
	end
	if block_start and block_end then
		paint(conflict_lines, block_start, block_end)
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = b,
		callback = function()
			vim.api.nvim_buf_clear_namespace(b, resolve_ns, 0, -1)
			local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
			local bs, be = locate(lines)
			if bs and be then
				paint(lines, bs, be)
			end
		end,
	})

	if block_start then
		vim.api.nvim_set_current_win(resolve_win)
		vim.api.nvim_win_set_cursor(resolve_win, { block_start + 1, 0 })
	end
end

---The live 0-indexed start row of the current conflict block in the resolve
---buffer, from the tracking extmark.
---@param self Review
---@return integer
function Review:_resolve_track_row()
	local r = self._resolve
	if r and r.block_mark and vim.api.nvim_buf_is_valid(r.resolve_buf) then
		local track_ns = vim.api.nvim_create_namespace("codeforge_resolve_track")
		local pos = vim.api.nvim_buf_get_extmark_by_id(r.resolve_buf, track_ns, r.block_mark, {})
		if pos and pos[1] then
			return pos[1]
		end
	end
	return r and r.first or 0
end

---Take "ours" into the editable conflict buffer: replace the whole merge-conflict block
---with U[R] (the user's pre-review version of the region), dropping the proposal side and
---the markers.
---@param self Review
function Review:_take_ours()
	if not self._resolve then
		return
	end
	local r = self._resolve
	local p = self:_placement_for(r.hunk_id)
	if not p then
		return
	end
	local ours_R = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	local lines = vim.api.nvim_buf_get_lines(r.resolve_buf, 0, -1, false)
	local lo, hi = find_conflict_block(lines, r.first, r.first + (r.region_len or 1) - 1, self:_resolve_track_row())
	if lo and hi then
		vim.api.nvim_buf_set_lines(r.resolve_buf, lo, hi + 1, false, ours_R)
	end
end

---Take the proposal into the editable conflict buffer: replace the whole
---merge-conflict block with the proposal side stored at resolve time,
---dropping the ours side and the markers. Lets you preview the proposal
---before committing via <C-x>f (you can still edit after taking, or undo).
---@param self Review
function Review:_take_proposal()
	if not self._resolve then
		return
	end
	local r = self._resolve
	local proposal_R = r.proposal_R
	if not proposal_R then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(r.resolve_buf, 0, -1, false)
	local lo, hi = find_conflict_block(lines, r.first, r.first + (r.region_len or 1) - 1, self:_resolve_track_row())
	if lo and hi then
		vim.api.nvim_buf_set_lines(r.resolve_buf, lo, hi + 1, false, proposal_R)
	end
end

---Find the placement for `hunk_id`
---@param self Review
---@param hunk_id string
---@return Placement?
function Review:_placement_for(hunk_id)
	for _, p in ipairs(self.placements) do
		if p.hunk_id == hunk_id then
			return p
		end
	end
end

---@param self Review
---@return integer?
function Review:_main_win()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "codeforge" then
			return w
		end
	end
end

---Confirm the resolution: splice the conflict buffer's contents back into the review
---buffer verbatim and mark the hunk 'accepted'. The conflict buffer is the full file
---P with the merge-conflict block around R; whatever the user left there is taken as
---is.
---@param self Review
function Review:confirm_resolve()
	if not self._resolve then
		return
	end
	local r = self._resolve
	local p = self:_placement_for(r.hunk_id)
	local lines = vim.api.nvim_buf_get_lines(r.resolve_buf, 0, -1, false)
	self:_restore_review_window()
	local hist_before = { status = "conflicted" }

	if p then
		local n = vim.api.nvim_buf_line_count(self.buf)
		local tail = n - (r.last + 1)
		local m = #lines
		local region = {}
		for i = r.first + 1, m - tail do
			region[#region + 1] = lines[i]
		end
		hist_before.region = vim.api.nvim_buf_get_lines(self.buf, r.first, r.last + 1, false)
		self:_apply_region(p, r.first, r.last, region)
		self.hunk_status[r.hunk_id] = "accepted"
		if #region > 0 then
			p.region_row = r.first
			p.region_mark = vim.api.nvim_buf_set_extmark(self.buf, diff.namespace, r.first, 0, {
				end_row = r.first + #region - 1,
				right_gravity = false,
				end_right_gravity = true,
			})
			p.region_len = #region
		end
		self:render()
		state.notify_change()
		self:_record_triage(p, hist_before, { status = "accepted", region = region })
		state.maybe_complete(state.change_for_path(self.path))
	end

	self._resolve = nil
end

---Sets up the resolve keymaps
---@param self Review
function Review:_setup_resolve_keymaps()
	local r = self._resolve
	local b = r and r.resolve_buf or self.buf
	local function map(key, fn, desc)
		vim.keymap.set("n", key, fn, { buffer = b, silent = true, desc = desc })
	end

	map("<C-x>o", function()
		self:_take_ours()
	end, "CodeForge: take ours")
	map("<C-x>p", function()
		self:_take_proposal()
	end, "CodeForge: take proposal")
	map("<C-x>f", function()
		self:confirm_resolve()
	end, "CodeForge: confirm resolve")
end

---Close any open resolve state without confirming
---@param self Review
function Review:_close_resolve()
	if not self._resolve then
		return
	end

	self:_restore_review_window()
	self._resolve = nil
end

---Restore the review buffer to its window, close the ours vsplit window,
---and wipe the scratch buffers
function Review:_restore_review_window()
	local r = self._resolve
	if not r then
		return
	end
	if r.review_win and vim.api.nvim_win_is_valid(r.review_win) then
		pcall(vim.api.nvim_win_set_buf, r.review_win, self.buf)
		vim.wo[r.review_win].winbar = ""
	end
	pcall(vim.cmd, "bdelete " .. r.resolve_buf)
end

---Replace the live buffer region `[first, last]` (0-indexed, inclusive)
---with `replacement`, clear this placement's decorations, and shift
---later placements by the line-count delta.
---@param self Review
---@param p Placement
---@param first integer 0-indexed first row
---@param last integer 0-indexed last row
---@param replacement string[]
function Review:_apply_region(p, first, last, replacement)
	vim.api.nvim_buf_set_lines(self.buf, first, last + 1, false, replacement)
	self._machine_tick = vim.api.nvim_buf_get_changedtick(self.buf)
	p.adds = {}
	p.add_contents = nil
	p.sign_marks = nil
	p.fold = nil
	p.fold_mark = nil
	self.expanded[p.hunk_id] = nil
end

---Install the review-buffer keymaps on `self.buf`.
---Reads the configured keys from `codeforge.config.keymaps`.
---@param self Review
function Review:setup_keymaps()
	local cfg = require("codeforge").config.keymaps or {}
	local function map(key, fn, desc)
		if not key then
			return
		end
		vim.keymap.set("n", key, fn, {
			buffer = self.buf,
			silent = true,
			desc = desc,
		})
	end
	map(cfg.toggle_fold, function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- to 0-indexed
		self:toggle_fold(row)
	end, "CodeForge: toggle deletion fold")
	map(cfg.restore, function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- to 0-indexed
		self:restore_fold(row)
	end, "CodeForge: restore deleted lines")
	map(cfg.reject_hunk, function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- to 0-indexed
		self:reject_hunk(row)
	end, "CodeForge: reject hunk")
	map(cfg.accept_hunk, function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- to 0-indexed
		self:accept_hunk(row)
	end, "CodeForge: accept hunk")
	map(cfg.resolve_hunk, function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- to 0-indexed
		self:resolve_hunk(row)
	end, "CodeForge: resolve conflicted hunk")
	map(cfg.dismiss, function()
		self:dismiss()
	end, "CodeForge: dismiss review")
	map(cfg.next_hunk, function()
		self:next_hunk()
	end, "CodeForge: next hunk")
	map(cfg.prev_hunk, function()
		self:prev_hunk()
	end, "CodeForge: previous hunk")
end

---@param self Review
function Review:open()
	self.buf_snapshot = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	if vim.bo[self.buf].filetype == "" then
		local ft = vim.filetype.match({ filename = self.path })
		if ft then
			vim.bo[self.buf].filetype = ft
		end
	end
	self:apply_hunks()
	self:render()
	self:setup_keymaps()
	state.set_review(self.path, self)

	self._reconcile_autocmd = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = self.buf,
		callback = function()
			if self._resolve then
				return
			end
			if vim.api.nvim_buf_get_changedtick(self.buf) == self._machine_tick then
				return
			end
			self.user_modified = true
			if self._reconcile_timer then
				self._reconcile_timer:stop()
				self._reconcile_timer:close()
			end
			self._reconcile_timer = vim.defer_fn(function()
				self._reconcile_timer = nil
				if vim.api.nvim_buf_is_valid(self.buf) and state.get_review(self.path) == self then
					self:_reconcile()
				end
			end, 120)
		end,
	})
end

---Reconcile pending-hunk signs with the live buffer after an edit: drop any sign
---whose recorded line content no longer matches the text under it, then re-render
---and refresh the sidebar so its L-label reflects where each hunk now sits.
---@param self Review
function Review:_reconcile()
	if self._resolve then
		return
	end

	local buf_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local changed = false
	for _, p in ipairs(self.placements) do
		local st = self.hunk_status[p.hunk_id]
		if st ~= "accepted" and st ~= "rejected" and p.sign_marks then
			local kept_adds, kept_kinds, kept_contents, kept_marks = {}, {}, {}, {}
			local ndropped = 0
			for i, mark in ipairs(p.sign_marks) do
				local drop = false
				if mark then
					local row = self:_row_of(mark)
					local expected = p.add_contents and p.add_contents[i]
					local actual = row ~= nil and buf_lines[row + 1] or nil
					if expected ~= nil and actual ~= expected then
						vim.api.nvim_buf_del_extmark(self.buf, diff.namespace, mark)
						drop = true
						changed = true
					end
				end
				if not drop then
					kept_adds[#kept_adds + 1] = p.adds and p.adds[i] or nil
					kept_kinds[#kept_kinds + 1] = p.kinds and p.kinds[i] or nil
					kept_contents[#kept_contents + 1] = p.add_contents and p.add_contents[i] or nil
					kept_marks[#kept_marks + 1] = mark
				else
					ndropped = ndropped + 1
				end
			end
			if ndropped > 0 then
				p.adds = kept_adds
				p.kinds = kept_kinds
				p.add_contents = kept_contents
				p.sign_marks = kept_marks
			end
		end
	end
	if changed then
		self:render()
	end
	state.notify_change()
end

---Remove the review-buffer keymaps installed by setup_keymaps
---@param self Review
function Review:_teardown_keymaps()
	if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
		return
	end
	local cfg = require("codeforge").config.keymaps or {}
	for _, key in ipairs({
		cfg.toggle_fold,
		cfg.restore,
		cfg.reject_hunk,
		cfg.accept_hunk,
		cfg.resolve_hunk,
		cfg.dismiss,
		cfg.next_hunk,
		cfg.prev_hunk,
	}) do
		if key then
			pcall(vim.keymap.del, "n", key, { buffer = self.buf })
		end
	end
end

---@param self Review
function Review:dismiss()
	if self._reconcile_timer then
		self._reconcile_timer:stop()
		self._reconcile_timer:close()
		self._reconcile_timer = nil
	end

	if self._reconcile_autocmd then
		pcall(vim.api.nvim_del_autocmd, self._reconcile_autocmd)
		self._reconcile_autocmd = nil
	end
	self:_teardown_keymaps()

	if self._resolve then
		self:_close_resolve()
	end

	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		for _, p in ipairs(self.placements) do
			local st = self.hunk_status[p.hunk_id]
			if st ~= "accepted" and st ~= "rejected" then
				local first, last = self:_region_rows(p)
				if first then
					local replacement =
						merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
					self:_apply_region(p, first, last, replacement)
				end
			end
		end
		vim.api.nvim_buf_clear_namespace(self.buf, diff.namespace, 0, -1)
	end
	state.clear_review(self.path)
end

return Review
