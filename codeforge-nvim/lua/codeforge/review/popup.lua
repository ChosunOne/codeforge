---On-demand hunk diff popup for the review buffer.
---A non-focusable float showing the diff of the hunk under the cursor,
---computed against the pre-review snapshot `U`.
---
---Behavior contract:
---  * `<C-x>p` (`keymaps.toggle_hunk_diff`) toggles it; pressing the key with
---    the cursor on another hunk re-anchors it; on the same hunk it closes.
---  * Placement is viewport-consistent: the popup hugs the hunk's on-screen
---    row (below it, flipped above when there is no room), stays glued while
---    the window scrolls or resizes, and pins to the nearer window edge when
---    the hunk itself scrolls out of view. Right edge stays pinned.
---  * Accepted and rejected hunks both work (a rejected hunk shows a "no
---    difference" note); refreshes/re-anchors when other hunks are resolved.
---  * Diffs taller than the window fill it and truncate with a "+N more
---    lines" hint.
---
---Diffing goes through `merge.diff_regions` (git).
local merge = require("codeforge.review.merge")
local diff = require("codeforge.review.diff")

local M = {}

M.namespace = vim.api.nvim_create_namespace("codeforge.popup")

---Context lines shown around each diff block.
local CONTEXT = 3

---Singleton popup state: opening a new instance replaces whatever is up.
M._hunk = nil ---@type {review: Review, review_win: integer, win: integer, buf: integer, hunk_id: string, rows: PopupRow[]}?
M._scroll_autocmd = nil ---@type integer?

---@class PopupRow
---@field text string rendered line (with -/+/space prefix for diff rows)
---@field kind string "removed"|"added"|"context"|"meta"

---Turn `diff_regions` output into popup rows: up to `ctx` lines of context
---from the new side around each block, then the block's removed and added
---lines.
---@param old_lines string[]
---@param new_lines string[]
---@param ctx integer
---@return PopupRow[] rows
function M.diff_rows(old_lines, new_lines, ctx)
	local regions = merge.diff_regions(old_lines, new_lines)
	local rows = {} ---@type PopupRow[]
	local prev = 0 -- 1-based last new-side line emitted
	for _, r in ipairs(regions) do
		-- A zero-count new range is anchored *after* new line r.ns, so the
		-- context before it runs through r.ns; otherwise it stops above the
		-- block's first new line.
		local gap_end = (r.nc > 0) and (r.ns - 1) or r.ns
		local gap_start = math.max(prev + 1, gap_end - ctx + 1)
		for i = gap_start, gap_end do
			rows[#rows + 1] = { text = " " .. (new_lines[i] or ""), kind = "context" }
		end
		for i = r.os, r.os + r.oc - 1 do
			rows[#rows + 1] = { text = "-" .. (old_lines[i] or ""), kind = "removed" }
		end
		for i = r.ns, r.ns + r.nc - 1 do
			rows[#rows + 1] = { text = "+" .. (new_lines[i] or ""), kind = "added" }
		end
		prev = (r.nc > 0) and (r.ns + r.nc - 1) or r.ns
	end
	if #new_lines > prev then
		local tail_start = math.max(prev + 1, #new_lines - ctx + 1)
		for i = tail_start, #new_lines do
			rows[#rows + 1] = { text = " " .. new_lines[i], kind = "context" }
		end
	end
	return rows
end

---The diff rows for one hunk placement: `U[R]` against the live buffer rows
---the placement spans. Empty result (rejected/unchanged hunk) becomes an
---explicit "no difference" note so the popup is never blank.
---@param review Review
---@param p Placement
---@return PopupRow[] rows
function M.hunk_rows(review, p)
	local lines = vim.api.nvim_buf_get_lines(review.buf, 0, -1, false)
	local u_R = merge.region_in(review.base_content, review.buf_snapshot, p.region_start, p.region_count)
	local live_R = {}
	local first, last = review:_region_rows(p)
	if first and last >= first then
		for i = first, last do
			live_R[#live_R + 1] = lines[i + 1]
		end
	end
	local rows = M.diff_rows(u_R, live_R, CONTEXT)
	if #rows == 0 then
		return { { text = "no difference vs pre-review", kind = "meta" } }
	end
	return rows
end

---@param rows PopupRow[]
---@return integer width display width of the widest row
local function rows_width(rows)
	local w = 0
	for _, r in ipairs(rows) do
		w = math.max(w, vim.fn.strdisplaywidth(r.text))
	end
	return w
end

---Write `rows` into a scratch popup buffer, styled per row kind.
---@param buf integer
---@param rows PopupRow[]
local function paint(buf, rows)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
	local lines = {}
	for i, r in ipairs(rows) do
		lines[i] = r.text
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for i, r in ipairs(rows) do
		local hl = (r.kind == "removed" and "CodeForgeHunkDeleted")
			or (r.kind == "added" and "CodeForgeHunkAdded")
			or (r.kind == "meta" and "Comment")
			or nil
		if hl then
			vim.api.nvim_buf_set_extmark(buf, M.namespace, i - 1, 0, {
				end_row = i - 1,
				end_col = #r.text,
				hl_group = hl,
				priority = 150,
			})
		end
	end
	vim.bo[buf].modifiable = false
end

local function scratch_buf(name)
	local b = vim.api.nvim_create_buf(false, true)
	vim.bo[b].buftype = "nofile"
	vim.bo[b].swapfile = false
	vim.bo[b].bufhidden = "wipe"
	vim.bo[b].modifiable = true
	pcall(vim.api.nvim_buf_set_name, b, name)
	return b
end

---Forget the popup state when its window is closed by any other means
---(parent window torn down, session exit).
local function watch_closed(fwin)
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(fwin),
		once = true,
		callback = function()
			if M._hunk and M._hunk.win == fwin then
				M._hunk = nil
			end
		end,
	})
end

---@param review Review
---@return integer index 1-based position of the placement among all hunks
local function placement_index(review, hunk_id)
	for i, p in ipairs(review.placements) do
		if p.hunk_id == hunk_id then
			return i
		end
	end
	return 1
end

---1-based viewport (screen) row of 0-indexed buffer row `lnum0` in window
---`win`, or nil when the row is scrolled out of view. Uses `screenpos`, which
---accounts for the review's own virtual lines (deletion folds); a redraw
---keeps the answer from lagging behind a just-made scroll.
---@param review Review
---@param win integer
---@param lnum0 integer 0-indexed buffer row
---@return integer? row 1-based viewport row, nil when scrolled out
local function viewport_row(review, win, lnum0)
	if not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	vim.cmd("redraw")
	local pos = vim.fn.screenpos(win, lnum0 + 1, 0)
	if pos.row == 0 then
		return nil
	end
	return pos.row
end

---Geometry for the popup: right-aligned, vertically adjacent to the hunk's
---anchor line *in the viewport* (buffer rows mean nothing once the file is
---scrolled). Prefers sitting below the hunk, flips above when there is no
---room, and pins to the nearer window edge when the hunk itself is scrolled
---out of view.
---@param review Review
---@param p Placement
---@param rows PopupRow[]
---@param review_win integer
---@return { row: integer, col: integer, width: integer, height: integer }
local function hunk_geometry(review, p, rows, review_win)
	local win_h = vim.api.nvim_win_get_height(review_win)
	local win_w = vim.api.nvim_win_get_width(review_win)
	local max_h = math.max(3, win_h - 3)
	local height = math.min(#rows, max_h)
	local width = math.min(rows_width(rows) + 2, math.max(10, win_w - 2))

	local anchor = review:_hunk_anchor(p) or 0
	-- a0: 0-indexed viewport row of the anchor line
	local vp = viewport_row(review, review_win, anchor)
	local a0
	if vp then
		a0 = vp - 1
	else
		local w0 = vim.fn.line("w0", review_win) - 1 -- 0-indexed top buffer row
		a0 = (anchor < w0) and -1 or win_h -- off-screen: pin toward nearer edge
	end

	local row
	if a0 + 1 + height + 1 <= win_h - 1 then
		row = a0 + 1 -- below: top border directly under the hunk's first line
	elseif a0 - height - 2 >= 0 then
		row = a0 - height - 2 -- above: bottom border directly over the hunk
	else
		row = math.max(0, math.min(a0 + 1, win_h - height - 2))
	end
	return { row = row, col = math.max(0, win_w - width - 1), width = width, height = height }
end

---Recompute the open popup's geometry (scroll, resize, or hunk moves). Only
---writes config when something actually changed, so the WinScrolled feedback
---loop terminates.
local function reposition_hunk()
	local h = M._hunk
	if not h or not vim.api.nvim_win_is_valid(h.win) or not vim.api.nvim_win_is_valid(h.review_win) then
		return
	end
	local p = h.review:_placement_for(h.hunk_id)
	if not p then
		M.close_hunk()
		return
	end
	local geo = hunk_geometry(h.review, p, h.rows, h.review_win)
	local cfg = vim.api.nvim_win_get_config(h.win)
	if
		math.abs((cfg.row or 0) - geo.row) > 0.5
		or math.abs((cfg.col or 0) - geo.col) > 0.5
		or cfg.width ~= geo.width
		or cfg.height ~= geo.height
	then
		vim.api.nvim_win_set_config(h.win, {
			relative = "win",
			win = h.review_win,
			row = geo.row,
			col = geo.col,
			width = geo.width,
			height = geo.height,
		})
	end
end

---Watch window scrolls/resizes so an open popup stays glued to its hunk.
---One guarded autocmd for the plugin's lifetime; no-ops when no popup is
---open and only reacts to the popup's own review window.
local function ensure_scroll_watch()
	if M._scroll_autocmd then
		return
	end
	M._scroll_autocmd = vim.api.nvim_create_autocmd("WinScrolled", {
		callback = function(args)
			if not M._hunk then
				return
			end
			local rw = M._hunk.review_win
			if rw and args.match == tostring(rw) then
				reposition_hunk()
			end
		end,
	})
end

---(Re)open the popup for placement `p` in `review`.
---@param review Review
---@param p Placement
function M._open_hunk(review, p)
	M.close_hunk()
	local review_win = vim.fn.bufwinid(review.buf)
	if not review_win or review_win < 0 then
		return
	end

	local status = review.hunk_status[p.hunk_id] or "pending"
	local rows = {
		{
			text = string.format("hunk %d/%d (%s)", placement_index(review, p.hunk_id), #review.placements, status),
			kind = "meta",
		},
	}
	vim.list_extend(rows, M.hunk_rows(review, p))

	local max_h = math.max(3, vim.api.nvim_win_get_height(review_win) - 3)
	if #rows > max_h then
		local hidden = #rows - (max_h - 1)
		rows = vim.list_slice(rows, 1, max_h - 1)
		rows[#rows + 1] = { text = string.format("… +%d more lines", hidden), kind = "meta" }
	end

	local geo = hunk_geometry(review, p, rows, review_win)
	local buf = scratch_buf("codeforge:hunk-diff")
	paint(buf, rows)
	local fwin = vim.api.nvim_open_win(buf, false, {
		relative = "win",
		win = review_win,
		anchor = "NW",
		row = geo.row,
		col = geo.col,
		width = geo.width,
		height = geo.height,
		style = "minimal",
		border = "rounded",
		focusable = false,
		zindex = 60,
	})
	M._hunk = { review = review, review_win = review_win, win = fwin, buf = buf, hunk_id = p.hunk_id, rows = rows }
	ensure_scroll_watch()
	watch_closed(fwin)
end

---Toggle the popup at the cursor. Open + different hunk under the cursor
---re-anchors; open + same hunk (or no hunk) closes; closed opens.
---@param review Review
function M.toggle_hunk(review)
	local row = vim.api.nvim_win_get_cursor(0)[1] - 1
	local p = review:hunk_at_row(row)
	if M._hunk and M._hunk.review == review and vim.api.nvim_win_is_valid(M._hunk.win) then
		if p and p.hunk_id ~= M._hunk.hunk_id then
			M._open_hunk(review, p)
		else
			M.close_hunk()
		end
		return
	end
	M.close_hunk()
	if not p then
		vim.notify("CodeForge: no hunk under cursor", vim.log.levels.INFO)
		return
	end
	M._open_hunk(review, p)
end

function M.close_hunk()
	local h = M._hunk
	M._hunk = nil
	if h and vim.api.nvim_win_is_valid(h.win) then
		pcall(vim.api.nvim_win_close, h.win, true)
	end
end

---Close the popup belonging to `review` (used by dismiss).
---@param review Review
function M.close(review)
	if M._hunk and M._hunk.review == review then
		M.close_hunk()
	end
end

---Rebuild the open popup's content (and anchor) after the review buffer or
---its decorations changed. No-op when nothing is open.
---@param review Review
function M.refresh(review)
	if M._hunk and M._hunk.review == review and vim.api.nvim_win_is_valid(M._hunk.win) then
		local p = review:_placement_for(M._hunk.hunk_id)
		if p then
			M._open_hunk(review, p)
		else
			M.close_hunk()
		end
	end
end

return M
