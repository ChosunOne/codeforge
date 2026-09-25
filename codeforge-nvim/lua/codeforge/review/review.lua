local state = require("codeforge.state")
local diff = require("codeforge.review.diff")
local merge = require("codeforge.review.merge")

---@class ResolveState
---@field hunk_id string
---@field first integer 0-indexed live buffer region start
---@field last integer 0-indexed live buffer end (inclusive)
---@field region_len integer number of buffer lines the conflict region occupies
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
---@field _baseline_lines string[]? buffer content at the last machine write/render,
---  used by the reconciler to tell an in-place amendment from a deletion
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

---Build the virt_lines block for a `fold` given its expanded state.
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
---@field emptied table? { anchor_row = integer, expected = table[]? }
---@field emptied_mark integer? extmark id for the emptied anchor
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
	self._baseline_lines = vim.deepcopy(out)
end

---Stores each extmark's id back on the placement so the live row can be
---derived later via `_row_of`. Each sign is given a range spanning its
---line content so in-line edits keep the sign on the line and insertions
---above shift it down with the content.
---
---The 0-indexed row a pending, emptied hunk is anchored at, or nil.
---@param self Review
---@param p Placement
---@return integer? row
function Review:_emptied_row(p)
	if not p.emptied then
		return nil
	end
	local r = self:_row_of(p.emptied_mark)
	if r ~= nil then
		return r
	end
	return p.emptied.anchor_row
end

---The 0-indexed row to anchor an emptied pending hunk at: the position its
---deleted lines occupied in the pre-edit baseline.
---@param old_adds integer[] the hunk's baseline rows, before the reconcile
---@param rows table<integer, integer|false> baseline row -> live row (false = deleted)
---@param buf_lines string[]
---@return integer row 0-indexed
function Review:_emptied_anchor_row(old_adds, rows, buf_lines)
	local best
	for _, old_row in ipairs(old_adds) do
		local mapped = rows[old_row]
		if type(mapped) == "number" then
			if best == nil or mapped < best then
				best = mapped
			end
		elseif mapped == false then
			for probe = old_row + 1, math.max(old_row + 1, #(self._baseline_lines or {})) do
				local candidate = rows[probe]
				if type(candidate) == "number" then
					if best == nil or candidate < best then
						best = candidate
					end
					break
				end
			end
		end
	end
	if best == nil then
		local prev = old_adds and old_adds[1]
		best = (type(prev) == "number" and prev) or 0
	end
	return math.max(0, math.min(best, math.max(0, #buf_lines - 1)))
end

---Reconcile a pending placement's sign marks with the live buffer: drop signs
---whose line was deleted, re-anchor signs whose content moved, and adopt
---in-place amendments.
---@param self Review
---@param p Placement
---@param rows table<integer, integer|false> baseline row -> live row (false = deleted)
---@param buf_lines string[]
---@return boolean changed
function Review:_reconcile_signs(p, rows, buf_lines)
	local changed = false
	local kept_adds, kept_kinds, kept_contents, kept_marks = {}, {}, {}, {}
	for i, mark in ipairs(p.sign_marks) do
		local expected = p.add_contents and p.add_contents[i]
		local old_row = p.adds and p.adds[i]
		local row = self:_row_of(mark)
		local drop = false
		local new_row = old_row

		if mark and expected ~= nil and not (row ~= nil and buf_lines[row + 1] == expected) then
			local mapped = old_row ~= nil and rows[old_row] or nil
			if mapped == false or mapped == nil then
				drop = true
			else
				new_row = mapped
			end
			vim.api.nvim_buf_del_extmark(self.buf, diff.namespace, mark)
			mark = nil
			changed = true
		end

		if drop then
		else
			kept_adds[#kept_adds + 1] = new_row
			kept_kinds[#kept_kinds + 1] = p.kinds and p.kinds[i] or nil
			local content = expected
			if mark == nil and new_row ~= nil and buf_lines[new_row + 1] ~= nil then
				content = buf_lines[new_row + 1]
			end
			kept_contents[#kept_contents + 1] = content
			kept_marks[#kept_marks + 1] = mark
		end
	end
	p.adds = kept_adds
	p.kinds = kept_kinds
	p.add_contents = kept_contents
	p.sign_marks = kept_marks
	return changed
end

---Remember a pending hunk's proposal rows and text, so a later undo that brings
---deleted lines back can re-detect them (`_recover_emptied`).
---@param old_adds integer[] baseline rows of the hunk's lines
---@param old_contents string[] the text of each row, when known
---@param old_kinds string[] per-row "added"|"modified"|"context"
---@return table[] expected { row = integer, text = string, kind = string? }
function Review:_expected_rows(old_adds, old_contents, old_kinds)
	local out = {}
	for i, row in ipairs(old_adds) do
		local text = old_contents[i]
		if text ~= nil then
			out[#out + 1] = { row = row, text = text, kind = old_kinds[i] }
		end
	end
	return out
end

---Recover a hunk whose lines an undo brought back.
---@param self Review
---@param p Placement
---@param buf_lines string[]
---@return boolean recovered
function Review:_recover_emptied(p, buf_lines)
	local expected = p.emptied and p.emptied.expected
	if not expected or #expected == 0 or #buf_lines == 0 then
		return false
	end
	local anchor = self:_emptied_row(p)
	if anchor == nil then
		return false
	end

	local want = expected[1].text
	local first
	for delta = 0, #buf_lines do
		for _, probe in ipairs({ anchor + 1 - delta, anchor + 2 + delta }) do
			if probe >= 1 and probe <= #buf_lines and buf_lines[probe] == want then
				first = probe
				break
			end
		end
		if first then
			break
		end
	end
	if first == nil then
		return false
	end

	local adds, contents, kinds = {}, {}, {}
	for k, item in ipairs(expected) do
		local row = first + (k - 1) -- 1-indexed
		if buf_lines[row] ~= item.text then
			break
		end
		adds[#adds + 1] = row - 1 -- stored 0-indexed, like apply_hunks
		contents[#contents + 1] = item.text
		kinds[#kinds + 1] = item.kind or "modified"
	end
	if #adds == 0 then
		return false
	end

	p.adds = adds
	p.add_contents = contents
	p.kinds = kinds
	p.emptied, p.emptied_mark = nil, nil
	return true
end

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
		if p.emptied and p.emptied_mark then
			local r = self:_row_of(p.emptied_mark)
			if r ~= nil then
				p.emptied.anchor_row = r
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

		if type(p.region_mark) == "number" then
			p.region_row = self:_row_of(p.region_mark)
		end
	end

	vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
	self.extmark_ids = {}

	for _, p in ipairs(self.placements) do
		if p.region_mark and p.region_len and p.region_len > 0 then
			local r = p.region_row
			if r ~= nil then
				p.region_mark = vim.api.nvim_buf_set_extmark(self.buf, ns, r, 0, {
					end_row = r + p.region_len - 1,
					right_gravity = true,
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

		if p.emptied then
			local id = vim.api.nvim_buf_set_extmark(self.buf, ns, p.emptied.anchor_row, 0, {
				end_row = p.emptied.anchor_row,
				sign_text = "~",
				sign_hl_group = "CodeForgeHunkEmptied",
			})
			self.extmark_ids[#self.extmark_ids + 1] = id
			p.emptied_mark = id
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

	require("codeforge.review.popup").refresh(self)

	-- Record the buffer as it stands after this render: the reconciler diffs
	-- against it to interpret the user's next edit.
	self._baseline_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
end

---The live 0-indexed row of extmark `id`, or nil if the mark is gone.
---This is the single source of truth for a placement's position.
---@param self Review
---@param id integer?
---@return integer? row 0-indexed
function Review:_row_of(id)
	if type(id) ~= "number" then
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

---The live buffer region [first, last] (0-indexed, inclusive) a placement
---occupies at final-assembly time. Resolved placements are located by their
---region extmark; unresolved ones by their pending anchors. Returns
---nil, nil when the placement cannot be located.
---@param self Review
---@param p Placement
---@return integer? first
---@return integer? last
function Review:_region_span(p)
	local st = self.hunk_status[p.hunk_id]
	if st == "accepted" or st == "rejected" then
		local r = self:_row_of(p.region_mark)
		if r ~= nil then
			return r, r + (p.region_len or 1) - 1
		end
		if p.region_len == 0 and p.region_row then
			return p.region_row, p.region_row - 1
		end
		return nil, nil
	end
	return self:_region_rows(p)
end

---Assemble the post-review buffer. Resolved hunk regions keep their live
---(resolved) text, and unresolved hunks and the regions between them fall back
---to the user's pre-review snapshot `U`, so edits outside the proposed hunks
---survive completion.
---
---Returns the assembled lines and a list of unresolved gap conflicts (a region
---where the pre-review snapshot and the live text both changed the same line).
---When conflicts is non-empty the caller must not apply the lines or finish the
---review.
---@param self Review
---@return string[] final
---@return table[] conflicts
function Review:assemble_final()
	local base = self.base_content
	local U = self.buf_snapshot
	local live = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local placements = self.placements
	local n = #placements

	local spans = {}
	local u_spans = {}

	---The snapshot `U` span holding base region [start, start+count-1], as a
	---1-indexed inclusive pair. A zero-length region (pure insertion/deletion
	---hunk) yields an empty span `[b, b-1]` at the boundary where base position
	---`start` sits in `U`, so `U`'s own lines there are preserved by the
	---surrounding gaps instead of being dropped.
	---@param start integer
	---@param count integer
	---@return integer? first
	---@return integer? last
	local function u_region(start, count)
		if count > 0 then
			return merge.region_span(base, U, start, count)
		end
		local b
		if start <= #base then
			local f = merge.region_span(base, U, start, 1)
			if f then
				b = f
			else
				b = 1
				for p = start - 1, 1, -1 do
					local _, l = merge.region_span(base, U, p, 1)
					if l then
						b = l + 1
						break
					end
				end
			end
		elseif #base > 0 then
			local _, l = merge.region_span(base, U, #base, 1)
			b = (l and l + 1) or (#U + 1)
		else
			b = 1
		end
		return b, b - 1
	end

	for i, p in ipairs(placements) do
		local f, l = self:_region_span(p)
		spans[i] = { first = f, last = l }
		local uf, ul = u_region(p.region_start, p.region_count)
		u_spans[i] = { first = uf, last = ul }
	end

	local out = {} ---@type string[]
	local conflicts = {} ---@type table[]
	local base_cursor = 1

	---Emit the base region between the previous hunk and placement `i`
	---(i = n + 1 for the trailing region). The gap's snapshot `U` content is
	---everything left between the adjacent hunks' U spans, so insertions the
	---user made at a hunk boundary or before line 1 are preserved rather than
	---dropped (or resurrected from base).
	---@param i integer
	local function emit_gap(i)
		local nextp = placements[i]
		local stop_base = nextp and (nextp.region_start - 1) or #base
		local start_base = base_cursor
		local count = stop_base - start_base + 1

		local prev_span = i > 1 and spans[i - 1] or nil
		local next_span = nextp and spans[i] or nil
		local live_start
		if i == 1 then
			live_start = 0
		elseif prev_span and prev_span.last then
			live_start = prev_span.last + 1
		end
		local live_stop
		if nextp then
			if next_span and next_span.first then
				live_stop = next_span.first - 1
			end
		else
			live_stop = #live - 1
		end

		-- U gap = U lines between the adjacent hunks' U spans
		local prev_u = i > 1 and u_spans[i - 1] or nil
		local next_u = nextp and u_spans[i] or nil
		local u_start
		if i == 1 then
			u_start = 1
		elseif prev_u and prev_u.last then
			u_start = prev_u.last + 1
		end
		local u_stop
		if nextp then
			if next_u and next_u.first then
				u_stop = next_u.first - 1
			end
		else
			u_stop = #U
		end

		local base_gap = {}
		for k = start_base, stop_base do
			base_gap[#base_gap + 1] = base[k]
		end
		local U_gap = {}
		if u_start and u_stop and u_stop >= u_start then
			for r = u_start, u_stop do
				U_gap[#U_gap + 1] = U[r]
			end
		elseif not (u_start and u_stop) then
			-- a neighbouring hunk's U span was unlocatable: fall back to the
			-- region's own base correspondence, else its base lines
			local u_first, u_last = merge.region_span(base, U, start_base, count)
			if u_first and u_last then
				for r = u_first, u_last do
					U_gap[#U_gap + 1] = U[r]
				end
			else
				for _, l in ipairs(base_gap) do
					U_gap[#U_gap + 1] = l
				end
			end
		end

		local live_gap = nil
		if live_start and live_stop then
			live_gap = {}
			for r = live_start, live_stop do
				live_gap[#live_gap + 1] = live[r + 1] or ""
			end
		end

		-- 3-way merge U against base with live as ours/theirs so disjoint
		-- pre-review and during-review edits in the same gap both survive. When
		-- both sides changed the same line no safe assembly exists: record the
		-- conflict (the caller refuses to finish) and emit the during-review
		-- text as a marker-free placeholder that is never applied as a result.
		if live_gap and not vim.deep_equal(live_gap, base_gap) then
			local res = merge.merge3(U_gap, base_gap, live_gap)
			if res.conflict then
				conflicts[#conflicts + 1] = {
					base_start = start_base,
					base_count = count,
				}
				for _, l in ipairs(live_gap) do
					out[#out + 1] = l
				end
			else
				for _, l in ipairs(res.lines) do
					out[#out + 1] = l
				end
			end
		else
			for _, l in ipairs(U_gap) do
				out[#out + 1] = l
			end
		end
		base_cursor = stop_base + 1
	end

	for i, p in ipairs(placements) do
		emit_gap(i)
		local st = self.hunk_status[p.hunk_id]
		local resolved = st == "accepted" or st == "rejected"
		local span = spans[i]
		local lines ---@type string[]
		if resolved and span.first then
			lines = {}
			for r = span.first, span.last do
				lines[#lines + 1] = live[r + 1]
			end
		else
			local src = (resolved and st == "accepted") and self.proposal or U
			local src_first, src_last = merge.region_span(base, src, p.region_start, p.region_count)
			lines = {}
			if src_first and src_last then
				for r = src_first, src_last do
					lines[#lines + 1] = src[r]
				end
			end
		end
		for _, l in ipairs(lines) do
			out[#out + 1] = l
		end
		base_cursor = p.region_start + p.region_count
	end
	emit_gap(n + 1)

	return out, conflicts
end

---Preflight final assembly without applying anything. Returns false with a
---message when a gap conflict would make finishing unsafe.
---@param self Review
---@return boolean ok
---@return string|nil message
function Review:preflight()
	if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
		return true
	end
	local _, conflicts = self:assemble_final()
	if #conflicts > 0 then
		return false,
			"your pre-review edits and during-review edits conflict in a region outside the hunks; "
				.. "reconcile or discard one side, then retry"
	end
	return true
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
		if p.region_len == 0 and p.region_row == row then
			return p
		end
		if self:_emptied_row(p) == row and p.emptied then
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
	if p.emptied then
		return self:_emptied_row(p)
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
	if p.emptied then
		local r = self:_emptied_row(p)
		if r ~= nil then
			return r, r - 1
		end
		return nil, nil
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

---Snapshot the data of every placement, keyed by hunk id.
---@param self Review
---@return table hunk_id -> snapshot
function Review:_snapshot_placements()
	local out = {}
	for _, p in ipairs(self.placements) do
		out[p.hunk_id] = {
			adds = p.adds and vim.deepcopy(p.adds) or nil,
			kinds = p.kinds and vim.deepcopy(p.kinds) or nil,
			add_contents = p.add_contents and vim.deepcopy(p.add_contents) or nil,
			fold = p.fold and vim.deepcopy(p.fold) or nil,
			emptied = p.emptied and vim.deepcopy(p.emptied) or nil,
			region_len = p.region_len,
			region_row = p.region_row,
		}
	end
	return out
end

---Keep a new file's atomic decision in sync with its sole insertion hunk.
---Added files have exactly one hunk.
---@param self Review
---@param hunk_id string
---@param status string? nil = pending
function Review:_set_hunk_status(hunk_id, status)
	self.hunk_status[hunk_id] = status
	local change = state.change_for_path(self.path)
	for _, file in ipairs(change and change.files or {}) do
		if
			file.path == self.path
			and file.status == "added"
			and #(file.hunks or {}) == 1
			and file.hunks[1].id == hunk_id
		then
			file.decision = (status == "accepted" or status == "rejected") and status or nil
			return
		end
	end
end

---Restore a historical state.
---@param self Review
---@param hunk_id string
---@param status string? nil = pending
---@param buffer_lines string[]
---@param placements table hunk_id -> snapshot
function Review:apply_history_state(hunk_id, status, buffer_lines, placements)
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, buffer_lines)
	self._machine_tick = vim.api.nvim_buf_get_changedtick(self.buf)
	self:_set_hunk_status(hunk_id, status)
	local change = state.change_for_path(self.path)
	for _, file in ipairs(change and change.files or {}) do
		if file.path == self.path and file.status == "added" then
			require("codeforge.review.fs").sync_added_file(change, file, file.decision, buffer_lines)
		end
	end
	for _, p in ipairs(self.placements) do
		local snap = placements and placements[p.hunk_id] or nil
		if snap then
			p.adds = snap.adds
			p.kinds = snap.kinds
			p.add_contents = snap.add_contents
			p.fold = snap.fold
			p.emptied = snap.emptied
			p.region_len = snap.region_len
			p.region_row = snap.region_row
			p.region_mark = (snap.region_len and snap.region_len > 0) and true or nil
			p.fold_mark = nil
			p.emptied_mark = nil
			p.sign_marks = {}
		end
	end
	self:render()
end

---Record a hunk triage action into the undo history
---@param self Review
---@param p Placement
---@param before table { status?, region? }
---@param buffer_before string[]
---@param placements_before table
---@param after table { status, region? }
function Review:_record_triage(p, before, buffer_before, placements_before, after)
	local change = state.change_for_path(self.path)
	after.buffer = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	after.placements = self:_snapshot_placements()
	before.buffer = buffer_before
	before.placements = placements_before
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
	local buffer_before = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local placements_before = self:_snapshot_placements()
	if first then
		hist_before.region = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	end
	if not first then
		self:_set_hunk_status(p.hunk_id, "rejected")
		state.notify_change()
		self:_record_triage(p, hist_before, buffer_before, placements_before, { status = "rejected" })
		return true
	end

	local replacement = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	self:_apply_region(p, first, last, replacement)
	self:_set_hunk_status(p.hunk_id, "rejected")
	self:render()
	state.notify_change()
	self:_record_triage(p, hist_before, buffer_before, placements_before, { status = "rejected", region = replacement })
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
	local buffer_before = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local placements_before = self:_snapshot_placements()
	if first then
		hist_before.region = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	end
	if not first then
		self:_set_hunk_status(p.hunk_id, "accepted")
		self:_sync_added_disk()
		state.notify_change()
		self:_record_triage(p, hist_before, buffer_before, placements_before, { status = "accepted" })
		return true
	end

	local ours = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	local base = merge.region_in(self.base_content, self.base_content, p.region_start, p.region_count)
	local cur = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	local res = merge.merge3(ours, base, cur)
	if res.conflict then
		self:_set_hunk_status(p.hunk_id, "conflicted")
		state.notify_change()
		self:_record_triage(p, hist_before, buffer_before, placements_before, { status = "conflicted" })
		return true
	end
	self:_apply_region(p, first, last, res.lines)
	self:_set_hunk_status(p.hunk_id, "accepted")
	self:render()
	self:_sync_added_disk()
	state.notify_change()
	self:_record_triage(p, hist_before, buffer_before, placements_before, { status = "accepted", region = res.lines })
	return true
end

---Write an accepted `added` file to disk now that its region is applied.
---@param self Review
function Review:_sync_added_disk()
	local change = state.change_for_path(self.path)
	for _, file in ipairs(change and change.files or {}) do
		if file.path == self.path and file.status == "added" then
			local final, conflicts = self:assemble_final()
			if conflicts and #conflicts > 0 then
				-- Unsafe assembly: preflight/completion will refuse and report it.
				return
			end
			require("codeforge.review.fs").sync_added_file(change, file, file.decision, final)
			return
		end
	end
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
	require("codeforge.history").begin("accept_pending")
	local n = self:_sweep(self._accept_placement, false)
	require("codeforge.history").commit()
	return n
end

---Reject every pending hunk in this review.
---@param self Review
---@return integer count
function Review:reject_pending()
	require("codeforge.history").begin("reject_pending")
	local n = self:_sweep(self._reject_placement, true)
	require("codeforge.history").commit()
	return n
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
	local buffer_before = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	local placements_before = self:_snapshot_placements()

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
		self:_set_hunk_status(r.hunk_id, "accepted")
		self:render()
		state.notify_change()
		self:_record_triage(p, hist_before, buffer_before, placements_before, { status = "accepted", region = region })
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
---later placements by the line-count delta. Re-anchors the placement at the
---written region (empty replacements keep only `region_row`, so resolved
---zero-length hunks — e.g. a rejected insertion — stay findable).
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
	p.region_row = first
	p.region_len = #replacement
	p.region_mark = nil
	if #replacement > 0 then
		p.region_mark = vim.api.nvim_buf_set_extmark(self.buf, diff.namespace, first, 0, {
			end_row = first + #replacement - 1,
			right_gravity = true,
			end_right_gravity = true,
		})
	end
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
	map(cfg.undo, function()
		require("codeforge.sidebar.actions").undo()
	end, "CodeForge: undo review action")
	map(cfg.redo, function()
		require("codeforge.sidebar.actions").redo()
	end, "CodeForge: redo review action")
	map(cfg.accept_pending, function()
		require("codeforge.sidebar.actions").accept_pending()
	end, "CodeForge: accept all pending hunks in this change")
	map(cfg.reject_pending, function()
		require("codeforge.sidebar.actions").reject_pending()
	end, "CodeForge: reject all pending hunks in this change")
	map(cfg.next_hunk, function()
		self:next_hunk()
	end, "CodeForge: next hunk")
	map(cfg.prev_hunk, function()
		self:prev_hunk()
	end, "CodeForge: previous hunk")
	map(cfg.toggle_hunk_diff, function()
		require("codeforge.review.popup").toggle_hunk(self)
	end, "CodeForge: toggle hunk diff popup")

	-- Tell mapping caches (which-key and friends) the buffer's local maps changed.
	require("codeforge.keymaps").announce(self.buf)
end

---Adopt a triage description restored by session.load: the decisions are
---known, but they have not been applied to a buffer yet, so `open` must replay
---them once the proposal is in place.
---@param self Review
---@param triage table { hunk_status, user_modified, expanded }
function Review:restore_triage(triage)
	self.hunk_status = {}
	for id, status in pairs(triage.hunk_status or {}) do
		self.hunk_status[id] = status
	end
	self.user_modified = triage.user_modified == true
	self.expanded = {}
	for id, value in pairs(triage.expanded or {}) do
		self.expanded[id] = value == true
	end
	self._needs_replay = true
end

---Re-apply restored decisions to the freshly built proposal.
---
---`apply_hunks` always rebuilds the buffer as the full proposal `P`, so a hunk
---that was decided before the restart currently shows `P` where it should show
---its outcome. Replay each decision with the same region semantics as the live
---accept/reject paths:
---
---  * accepted: the region already holds `P`, so only its span is recorded
---    (with `U == O` this is exactly the clean accept that produced the status),
---  * rejected: the region reverts to the pre-review snapshot `U`,
---  * conflicted: left as the proposal; the status stays `conflicted` so the
---    existing resolve flow owns it.
---
---The decisions themselves are NOT revisited: this writes no history, does not
---notify state, and must never complete the change.
---@param self Review
function Review:_replay_decisions()
	-- render() first: region location reads live extmarks, and placements are
	-- only discoverable through them.
	self:render()
	for _, p in ipairs(self.placements) do
		local status = self.hunk_status[p.hunk_id]
		if status == "accepted" or status == "rejected" then
			local first, last = self:_region_rows(p)
			if first then
				local replacement
				if status == "rejected" then
					replacement = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
				else
					replacement = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
				end
				self:_apply_region(p, first, last, replacement)
			end
		end
	end
	self:render()
end

---@param self Review
function Review:open()
	self.buf_snapshot = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	if
		#self.base_content == 0
		and #self.buf_snapshot == 1
		and self.buf_snapshot[1] == ""
		and not vim.bo[self.buf].modified
		and vim.fn.filereadable(self.path) == 0
	then
		self.buf_snapshot = {}
	end
	if vim.bo[self.buf].filetype == "" then
		local ft = vim.filetype.match({ filename = self.path })
		if ft then
			vim.bo[self.buf].filetype = ft
		end
	end
	self:apply_hunks()
	self:render()
	if self._needs_replay then
		self._needs_replay = nil
		self:_replay_decisions()
	end
	self:setup_keymaps()
	state.set_review(self.path, self)
	self:_install_reconcile_watch()
end

---Install the TextChanged/TextChangedI reconcile watcher on the
---review buffer.
---@param self Review
function Review:_install_reconcile_watch()
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

---Re-register a review whose change was revived after completion
---@param self Review
function Review:revive()
	if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
		return
	end
	state.set_review(self.path, self)
	require("codeforge.review.buffer").rearm_review(self.path, self.buf)
	self:render()
	self:setup_keymaps()
	self:_install_reconcile_watch()
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
	local rows = merge.row_map(self._baseline_lines or buf_lines, buf_lines)
	local changed = false
	for _, p in ipairs(self.placements) do
		local st = self.hunk_status[p.hunk_id]
		if st ~= "accepted" and st ~= "rejected" and p.sign_marks then
			local recovered = p.emptied and self:_recover_emptied(p, buf_lines)
			if recovered then
				changed = true
			else
				local old_adds = vim.deepcopy(p.adds or {})
				local old_contents = vim.deepcopy(p.add_contents or {})
				local old_kinds = vim.deepcopy(p.kinds or {})
				if self:_reconcile_signs(p, rows, buf_lines) then
					changed = true
				end
				local has_lines = #(p.adds or {}) > 0 or p.fold ~= nil
				if has_lines then
					if p.emptied then
						p.emptied, p.emptied_mark = nil, nil
						changed = true
					end
				elseif not p.emptied then
					p.emptied = {
						anchor_row = self:_emptied_anchor_row(old_adds, rows, buf_lines),
						expected = self:_expected_rows(old_adds, old_contents, old_kinds),
					}
					changed = true
				end
			end
		end
	end
	local popup = require("codeforge.review.popup")
	if changed then
		self:render() -- rebuilds signs and refreshes an open popup
	else
		popup.refresh(self)
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
		cfg.undo,
		cfg.redo,
		cfg.accept_pending,
		cfg.reject_pending,
		cfg.next_hunk,
		cfg.prev_hunk,
		cfg.toggle_hunk_diff,
	}) do
		if key then
			pcall(vim.keymap.del, "n", key, { buffer = self.buf })
		end
	end

	-- Removal changes the buffer's local maps too; announce so caches drop
	-- the now-dangling entries.
	require("codeforge.keymaps").announce(self.buf)
end

---@param self Review
---@return boolean finished
function Review:dismiss()
	-- Refuse before any teardown: a conflicting gap has no safe assembly.
	local pre_ok, pre_msg = self:preflight()
	if not pre_ok then
		vim.notify("CodeForge: " .. pre_msg, vim.log.levels.WARN)
		return false
	end

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
	require("codeforge.review.popup").close(self)

	if self._resolve then
		self:_close_resolve()
	end

	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		local final = self:assemble_final()
		vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, final)
		self._machine_tick = vim.api.nvim_buf_get_changedtick(self.buf)
		vim.api.nvim_buf_clear_namespace(self.buf, diff.namespace, 0, -1)
	end
	require("codeforge.review.buffer").detach_save_guard(self.buf)
	state.clear_review(self.path)
	return true
end

return Review
