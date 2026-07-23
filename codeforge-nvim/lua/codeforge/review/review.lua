local state = require("codeforge.state")
local diff = require("codeforge.review.diff")
local merge = require("codeforge.review.merge")

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
---@field adds integer[]?
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

		local fold ---@type Fold
		if removed > 0 then
			local anchor_row = #out - 1 -- 0-indexed last written proposal line
			if anchor_row < 0 then
				anchor_row = 0
			end
			fold = { anchor_row = anchor_row, count = removed, lines = removed_lines }
		end

		cursor = cursor + h.old_lines

		local adds = {} ---@type integer[]
		for _, line in ipairs(h.lines) do
			local prefix = line:sub(1, 1)
			if prefix == "+" or prefix == " " then
				out[#out + 1] = line:sub(2)
				if prefix == "+" then
					adds[#adds + 1] = #out - 1 -- 0-indexed proposal row just written
				end
			end
		end

		placements[#placements + 1] = {
			hunk_id = h.id,
			adds = adds,
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
			})
			self.extmark_ids[#self.extmark_ids + 1] = id
		end

		for _, row in ipairs(p.adds or {}) do
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
		-- TODO: conflict resolution
		return
	end
	self:_apply_region(p, first, last, res.lines)
	self.hunk_status[p.hunk_id] = "accepted"
	self:render()
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
	if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
		vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self.buf_snapshot)
		vim.api.nvim_buf_clear_namespace(self.buf, diff.namespace, 0, -1)
	end
	state.clear_review(self.path)
end

return Review
