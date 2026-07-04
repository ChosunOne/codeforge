local state = require("codeforge.state")
local diff = require("codeforge.review.diff")

---@class Review
---@field path string
---@field buf integer the file buffer under review
---@field base_content string[] what the AI diffed against
---@field buf_snapshot string[] the user's pre-review buffer content
---@field hunks Hunk[] hunks for this file
---@field placements Placement[] per-hunk placement plan
---@field extmark_ids integer[] extmark ids created by the render

local Review = {}
Review.__index = Review

---@class Placement
---@field hunk_id string
---@field adds integer[]?
---@field fold Fold?

---@class Fold
---@field anchor_row integer
---@field count integer

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
		for _, line in ipairs(h.lines) do
			if line:sub(1, 1) == "-" then
				removed = removed + 1
			end
		end

		local fold ---@type Fold
		if removed > 0 then
			local anchor_row = #out - 1 -- 0-indexed last written proposal line
			if anchor_row < 0 then
				anchor_row = 0
			end
			fold = { anchor_row = anchor_row, count = removed }
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
			local count = p.fold.count
			local text = string.format("- %d %s removed", count, count == 1 and "line" or "lines")
			local id = vim.api.nvim_buf_set_extmark(self.buf, ns, p.fold.anchor_row, 0, {
				virt_lines = { { { text, "CodeForgeHunkDeleted" } } },
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

---@param self Review
function Review:open()
	self.buf_snapshot = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
	self:apply_hunks()
	self:render()
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
