local state = require("codeforge.state")
local diff = require("codeforge.review.diff")
local merge = require("codeforge.review.merge")

---@class ResolveState
---@field hunk_id string
---@field first integer 0-indexed live buffer region start
---@field last integer 0-indexed live buffer region end (inclusive)
---@field ours_buf integer
---@field base_buf integer

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
local Review = {}
Review.__index = Review

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

---@class Placement
---@field hunk_id string
---@field adds integer[]? rows of the hunk's new lines (added+modified+context)
---@field kinds string[]? per adds[i]: "added"|"modified"|"context"
---@field fold Fold?
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
	vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, out)
end

---Read `self.placements` and place extmarks on `self.buf`.
---Records extmark ids on `self.extmark_ids`.
---@param self Review
function Review:render()
	local ns = diff.namespace

	vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
	self.extmark_ids = {}

	for _, p in ipairs(self.placements) do
		if p.fold then
			local expanded = self.expanded[p.hunk_id] == true
			local id = vim.api.nvim_buf_set_extmark(self.buf, ns, p.fold.anchor_row, 0, {
				virt_lines = fold_virt_lines(p.fold, expanded),
				sign_text = "-",
				sign_hl_group = "CodeForgeHunkDeleted",
			})
			self.extmark_ids[#self.extmark_ids + 1] = id
		end

		for i, row in ipairs(p.adds or {}) do
			local kind = p.kinds and p.kinds[i] or "added"
			if kind == "context" then
				-- no highlight, skip
			elseif kind == "modified" then
				local id = vim.api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
					end_row = row,
					hl_group = "CodeForgeHunkModified",
					sign_text = "~",
					sign_hl_group = "CodeForgeHunkModified",
				})
				self.extmark_ids[#self.extmark_ids + 1] = id
			else
				local id = vim.api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
					end_row = row,
					hl_group = "CodeForgeHunkAdded",
					sign_text = "+",
					sign_hl_group = "CodeForgeHunkAdded",
				})
				self.extmark_ids[#self.extmark_ids + 1] = id
			end
		end
	end
end

---Toggle the deletion fold anchored at buffer row `row` (0-indexed)
---between collapsed (hint) and expanded (deleted lines). No-op if no fold is
---anchored at `row`.
---@param self Review
---@param row integer 0-indexed buffer row
function Review:toggle_fold(row)
	for _, p in ipairs(self.placements) do
		if p.fold and p.fold.anchor_row == row then
			self.expanded[p.hunk_id] = not (self.expanded[p.hunk_id] == true)
			self:render()
			return
		end
	end
end

---Restore the deletion fold anchored at buffer row `row` (0-indexed)
---Promote the deleted lines to real buffer text at that position and drop the fold.
---No-op if no fold is anchored at `row`. Subsequent extmark rows are shifted to
---account for the inserted lines
---@param self Review
---@param row integer 0-indexed buffer row
function Review:restore_fold(row)
	for _, p in ipairs(self.placements) do
		if p.fold and p.fold.anchor_row == row then
			local count = p.fold.count
			local lines = p.fold.lines
			vim.api.nvim_buf_set_lines(self.buf, row + 1, row + 1, false, lines)
			p.fold = nil
			self.expanded[p.hunk_id] = nil
			for _, q in ipairs(self.placements) do
				if q.fold and q.fold.anchor_row > row then
					q.fold.anchor_row = q.fold.anchor_row + count
				end
				for j, r in ipairs(q.adds or {}) do
					if r > row then
						q.adds[j] = r + count
					end
				end
			end
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
		if p.fold and p.fold.anchor_row == row then
			return p
		end
		for _, r in ipairs(p.adds or {}) do
			if r == row then
				return p
			end
		end
	end
	return nil
end

---The anchor row (0-indexed) of a placement's hunk: its deletion fold if it
---has one, else its first added line.
---@param p Placement
---@return integer?
local function hunk_anchor(p)
	if p.fold then
		return p.fold.anchor_row
	end
	if p.adds and #p.adds > 0 then
		return p.adds[1]
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
		local a = hunk_anchor(p)
		if a ~= nil and a > cur then
			best = a
			break
		end
	end
	if best == nil then
		best = hunk_anchor(pending[1])
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
		local a = hunk_anchor(p)
		if a ~= nil and a <= cur then
			cur_anchor = a
		end
	end
	local best = nil
	for i = #pending, 1, -1 do
		local a = hunk_anchor(pending[i])
		if a ~= nil and cur_anchor ~= nil and a < cur_anchor then
			best = a
			break
		end
	end
	if best == nil then
		best = hunk_anchor(pending[#pending])
	end
	if best ~= nil then
		vim.api.nvim_win_set_cursor(0, { best + 1, 0 })
	end
end

---Reject the hunk covering buffer `row`: drop the AI change for that hunk's
---region so the buffer reflects `U` there. For a pure-add hunk this removes
---the added lines; a deletion fold is restored as real text. Marks the hunk
---'rejected'. No-op if no hunk covers `row` or it is already rejected.
---@param self Review
---@param row integer 0-indexed buffer row
function Review:reject_hunk(row)
	local p = self:hunk_at_row(row)
	if not p or self.hunk_status[p.hunk_id] == "rejected" then
		return
	end
	local adds = p.adds or {}
	local first = p.fold and p.fold.anchor_row + 1 or adds[1]
	local last = adds[#adds] or (p.fold and p.fold.anchor_row)
	if not first then
		self.hunk_status[p.hunk_id] = "rejected"
		return
	end

	local replacement = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	self:_apply_region(p, first, last, replacement)
	self.hunk_status[p.hunk_id] = "rejected"
	self:render()
end

function Review:accept_hunk(row)
	local p = self:hunk_at_row(row)
	if not p or self.hunk_status[p.hunk_id] == "accepted" or self.hunk_status[p.hunk_id] == "rejected" then
		return
	end
	local adds = p.adds or {}
	local first = p.fold and p.fold.anchor_row + 1 or adds[1]
	local last = adds[#adds] or (p.fold and p.fold.anchor_row)
	if not first then
		self.hunk_status[p.hunk_id] = "accepted"
		return
	end

	local ours = merge.region_in(self.base_content, self.buf_snapshot, p.region_start, p.region_count)
	local base = merge.region_in(self.base_content, self.base_content, p.region_start, p.region_count)
	local cur = vim.api.nvim_buf_get_lines(self.buf, first, last + 1, false)
	local res = merge.merge3(ours, base, cur)
	if res.conflict then
		self.hunk_status[p.hunk_id] = "conflicted"
		return
	end
	self:_apply_region(p, first, last, res.lines)
	self.hunk_status[p.hunk_id] = "accepted"
	self:render()
end

---Enter native 3-way diff resolution for the conflicted hunk covering `row`.
---Opens read-only scratch buffers for ours (U[R]) and base (O[R]), diffthis's
---the live buffer + both scratches, and installs resolve keymaps (<C-x>o take
---ours, <C-x>p take theirs, <C-x>f confirm). No-op if the hunk is not conflicted
---@param self Review
---@param row integer 0-indexed buffer row
function Review:resolve_hunk(row)
	local p = self:hunk_at_row(row)
	if not p or self.hunk_status[p.hunk_id] ~= "conflicted" then
		return
	end
	local adds = p.adds or {}
	local first = p.fold and p.fold.anchor_row + 1 or adds[1]
	local last = adds[#adds] or (p.fold and p.fold.anchor_row)
	if not first then
		return
	end

	if self._resolve and self._resolve.hunk_id == p.hunk_id then
		return
	end
	self:_close_resolve()

	local ours_lines = self.buf_snapshot
	local base_lines = self.base_content

	local function make_scratch(label, lines)
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(b, "codeforge.resolve." .. label)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
		vim.bo[b].modifiable = false
		vim.bo[b].bufhidden = "wipe"
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, b)
		return b
	end

	local ours_buf = make_scratch("ours", ours_lines)
	local base_buf = make_scratch("base", base_lines)

	for _, b in ipairs({ ours_buf, base_buf }) do
		local w = win_for_buf(b)
		if w then
			vim.api.nvim_set_current_win(w)
			vim.cmd("diffthis")
		end
	end

	local live_win = win_for_buf(self.buf) or self:_main_win()
	if live_win then
		vim.api.nvim_set_current_win(live_win)
	end
	vim.cmd("diffthis")
	if live_win then
		vim.api.nvim_set_current_win(live_win)
	end

	self._resolve = { hunk_id = p.hunk_id, first = first, last = last, ours_buf = ours_buf, base_buf = base_buf }
	self:_setup_resolve_keymaps()
end

---Take side `which` ("ours" = U, "base" = O) into the live buffer's
---conflicted region, splicing the region directly. The 3-way diffthis
---stays up for visual reference. Updates the stored region end to the
---new length.
---@param self Review
---@param which string "ours" or "base"
function Review:_take_side(which)
	if not self._resolve then
		return
	end
	local r = self._resolve
	local p = self:_placement_for(r.hunk_id)
	if not p then
		return
	end
	local src = (which == "ours") and self.buf_snapshot or self.base_content
	local lines = merge.region_in(self.base_content, src, p.region_start, p.region_count)
	vim.api.nvim_buf_set_lines(self.buf, r.first, r.last + 1, false, lines)
	r.last = r.first + #lines - 1
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

---Confirm the resolution: the live buffer's resolved region becomes final[R],
---mark the hunk 'accepted', diffoff, close scratch buffers, restore keymaps.
---@param self Review
function Review:confirm_resolve()
	if not self._resolve then
		return
	end
	local r = self._resolve
	local p = self:_placement_for(r.hunk_id)
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if
			vim.api.nvim_win_get_buf(w) == self.buf
			or vim.api.nvim_win_get_buf(w) == r.ours_buf
			or vim.api.nvim_win_get_buf(w) == r.base_buf
		then
			vim.api.nvim_set_current_win(w)
			vim.cmd("diffoff")
		end
	end

	vim.cmd("bdelete " .. r.ours_buf)
	vim.cmd("bdelete " .. r.base_buf)

	if p then
		local cur = vim.api.nvim_buf_get_lines(self.buf, r.first, r.last + 1, false)
		self:_apply_region(p, r.first, r.last, cur)
		self.hunk_status[r.hunk_id] = "accepted"
		self:render()
	end

	self._resolve = nil
	self:_teardown_resolve_keymaps()
end

---Sets up the resolve keymaps
---@param self Review
function Review:_setup_resolve_keymaps()
	local function map(key, fn, desc)
		vim.keymap.set("n", key, fn, { buffer = self.buf, silent = true, desc = desc })
	end

	map("<C-x>o", function()
		self:_take_side("ours")
	end, "CodeForge: take ours (U)")
	map("<C-x>p", function()
		self:_take_side("base")
	end, "CodeForge: take base (O)")
	map("<C-x>f", function()
		self:confirm_resolve()
	end, "CodeForge: confirm resolve")
end

---Remove keymaps for conflict resolution
function Review:_teardown_resolve_keymaps()
	for _, k in ipairs({ "<C-x>o", "<C-x>p", "<C-x>f" }) do
		pcall(vim.keymap.del, "n", k, { buffer = self.buf })
	end
end

---Close any open resolve state without confirming
---@param self Review
function Review:_close_resolve()
	if not self._resolve then
		return
	end
	local r = self._resolve
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local b = vim.api.nvim_win_get_buf(w)
		if b == self.buf or b == r.ours_buf or b == r.base_buf then
			vim.api.nvim_set_current_win(w)
			vim.cmd("diffoff")
		end
	end

	pcall(vim.cmd, "bdelete " .. r.ours_buf)
	pcall(vim.cmd, "bdelete " .. r.base_buf)
	self._resolve = nil
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
	local delta = #replacement - (last - first + 1)
	p.adds = {}
	p.fold = nil
	self.expanded[p.hunk_id] = nil
	if delta ~= 0 then
		for _, q in ipairs(self.placements) do
			if q.fold and q.fold.anchor_row > last then
				q.fold.anchor_row = q.fold.anchor_row + delta
			end
			for j, r in ipairs(q.adds or {}) do
				if r > last then
					q.adds[j] = r + delta
				end
			end
		end
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
	self:apply_hunks()
	self:render()
	self:setup_keymaps()
	state.set_review(self.path, self)
end

---@param self Review
function Review:dismiss()
	if self._resolve then
		self:_close_resolve()
	end

	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		for _, p in ipairs(self.placements) do
			local st = self.hunk_status[p.hunk_id]
			if st ~= "accepted" and st ~= "rejected" then
				local adds = p.adds or {}
				local first = p.fold and p.fold.anchor_row + 1 or adds[1]
				local last = adds[#adds] or (p.fold and p.fold.anchor_row)
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
