---CodeForge review merge/alignment helpers
---Uses `git` as the diff/merge engine; this module only parses git's output
---(hunk headers / merge exit codes)
---
local M = {}

---@class AlignBlock
---@field kind string "unchanged"|"changed"
---@field b_start integer 1-indexed start (inclusive) in base
---@field b_count integer number of base lines
---@field o_start integer 1-indexed start (inclusive) in other
---@field o_count integer number of other lines

---Result of a 3-way merge via `git merge-file`
---@class MergeResult
---@field ok boolean true if merged cleanly
---@field conflict boolean true if git merge-file reported conflicts
---@field lines string[] merged content (may contain conflict markers if conflict)

---Build the ordered list of correspondence blocks between `base` and `other`
---from `diff_regions(base, other)`.
---@param base string[]
---@param other string[]
---@return AlignBlock[] blocks
local function align_blocks(base, other)
	local regions = M.diff_regions(base, other)
	local blocks = {} ---@type AlignBlock[]
	local bpos = 1 -- next base line to place
	local opos = 1 -- next other line to place
	for _, r in ipairs(regions) do
		local ub_end = (r.oc > 0) and (r.os - 1) or r.os
		local uo_end = (r.nc > 0) and (r.ns - 1) or r.ns
		if ub_end >= bpos then
			table.insert(blocks, {
				kind = "unchanged",
				b_start = bpos,
				b_count = ub_end - bpos + 1,
				o_start = opos,
				o_count = uo_end - opos + 1,
			})
		end

		if r.oc > 0 or r.nc > 0 then
			table.insert(blocks, {
				kind = "changed",
				b_start = (r.oc > 0) and r.os or (r.os + 1),
				b_count = r.oc,
				o_start = (r.nc > 0) and r.ns or (r.ns + 1),
				o_count = r.nc,
			})
		end
		bpos = (r.oc > 0) and (r.os + r.oc) or (r.os + 1)
		opos = (r.nc > 0) and (r.ns + r.nc) or (r.ns + 1)
	end

	if bpos <= #base or opos <= #other then
		table.insert(blocks, {
			kind = "unchanged",
			b_start = bpos,
			b_count = #base - bpos + 1,
			o_start = opos,
			o_count = #other - opos + 1,
		})
	end
	return blocks
end

---Run `git diff --unified=0` between two line-lists and return the changed
---regions as git reports them: each `{os, oc, ns, nc }` where
---`os/oc` is the old (base) range start (1-indexed) and count, and `ns/nc`
---the new (other) range. Counts follow git's header convention: 1-count ranges
---omit the count; 0-count ranges keep the anchor line number git emits.
---@param base string[]
---@param other string[]
---@return table[] regions list of { os integer, oc integer, ns integer, nc integer }
function M.diff_regions(base, other)
	if #base == 0 and #other == 0 then
		return {}
	end

	local fa = vim.fn.tempname()
	local fb = vim.fn.tempname()
	vim.fn.writefile(base, fa)
	vim.fn.writefile(other, fb)

	local out = vim.fn.systemlist({ "git", "diff", "--unified=0", "--no-index", "--no-color", fa, fb })
	vim.fn.delete(fa)
	vim.fn.delete(fb)

	local regions = {}
	for _, line in ipairs(out) do
		local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
		if os then
			table.insert(regions, {
				os = tonumber(os),
				oc = (oc == "" or oc == nil) and 1 or tonumber(oc),
				ns = tonumber(ns),
				nc = (nc == "" or nc == nil) and 1 or tonumber(nc),
			})
		end
	end
	return regions
end

---Map a base (O) region `[start, start + count]` (1-indexed, count lines) to the
---corresponding lines in `other`, using git's diff to handle drift (lines
---added/removed before the region). Unchanged regions map 1:1 with the
---accumulated drift; if the region overlaps a region the other side changed,
---that changed block's other lines are taken (so e.g. reject returns the user's
---edited version of the region).
---@param base string[] O
---@param other string[] U or P'
---@param start integer 1-indexed base start
---@param count integer base line count
---@return string[] other_lines
function M.region_in(base, other, start, count)
	if count == 0 then
		return {}
	end

	local blocks = align_blocks(base, other)
	local want_end = start + count - 1
	local out = {}
	local visited_changed = {} ---@type table<integer, boolean>
	for _, blk in ipairs(blocks) do
		if blk.kind == "unchanged" then
			local b_end = blk.b_start + blk.b_count - 1
			if b_end >= start and blk.b_start <= want_end then
				local lo = math.max(start, blk.b_start)
				local hi = math.min(want_end, b_end)
				for i = lo, hi do
					local offset = i - blk.b_start
					out[#out + 1] = other[blk.o_start + offset]
				end
			end
		elseif blk.kind == "changed" and blk.b_count > 0 then
			local b_end = blk.b_start + blk.b_count - 1
			if b_end >= start and blk.b_start <= want_end and not visited_changed[blk.b_start] then
				visited_changed[blk.b_start] = true
				for i = blk.o_start, blk.o_start + blk.o_count - 1 do
					out[#out + 1] = other[i]
				end
			end
		end
	end
	return out
end

---Run `git merge-file -p ours base theirs` and return the result.
---@param ours string[]
---@param base string[]
---@param theirs string[]
---@return MergeResult
function M.merge3(ours, base, theirs)
	return M.merge3_named(ours, base, theirs, nil, nil)
end

---3-way merge producing the full file with git conflict markers when there's
---a conflict. Uses labels for the conflict markers. Returns { ok, conflict, lines }
---where `lines` is the full file (with conflict markers if conflict).
---@param ours string[]
---@param base string[]
---@param theirs string[]
---@param ours_label? string marker label for the ours side (default "ours")
---@param theirs_label? string marker label for the theirs side (default "theirs")
---@return { ok: boolean, conflict: boolean, lines: string[] }
function M.merge3_named(ours, base, theirs, ours_label, theirs_label)
	local ol = ours_label or "ours"
	local bl = "base"
	local tl = theirs_label or "theirs"
	local fa, fb, fc = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
	vim.fn.writefile(ours, fa)
	vim.fn.writefile(base, fb)
	vim.fn.writefile(theirs, fc)
	local out = vim.fn.systemlist({ "git", "merge-file", "-p", "-L", ol, "-L", bl, "-L", tl, fa, fb, fc })
	local code = vim.v.shell_error
	vim.fn.delete(fa)
	vim.fn.delete(fb)
	vim.fn.delete(fc)
	if code < 0 then
		error("codeforge: git merge-file failed: " .. table.concat(out, "\n"))
	end
	return { ok = (code == 0), conflict = (code > 0), lines = out }
end

---Classify each new line of a modify hunk as "context", "modified", or "added"
---using `git diff --word-diff=plain` between the old block and the new block.
---@param old_block string[] the hunk's removed lines
---@param new_block string[] the hunk's added lines
---@return string[] kinds one per new block line: "context"|"modified"|"added"
function M.classify_modify(old_block, new_block)
	if #new_block == 0 then
		return {}
	end
	local fa, fb = vim.fn.tempname(), vim.fn.tempname()
	vim.fn.writefile(old_block, fa)
	vim.fn.writefile(new_block, fb)
	local out = vim.fn.systemlist({
		"git",
		"diff",
		"--no-index",
		"--no-color",
		"--word-diff=plain",
		fa,
		fb,
	})
	vim.fn.delete(fa)
	vim.fn.delete(fb)

	local kinds = {}
	local in_hunk = false
	for _, line in ipairs(out) do
		if line:sub(1, 2) == "@@" then
			in_hunk = true
		elseif in_hunk then
			local has_rem = line:find("[-", 1, true) ~= nil
			local has_add = line:find("{+", 1, true) ~= nil
			if has_rem and not has_add then
				--skip, no new line
			elseif has_rem and has_add then
				kinds[#kinds + 1] = "modified"
			elseif has_add then
				kinds[#kinds + 1] = "added"
			else
				kinds[#kinds + 1] = "context"
			end
		end
	end

	if #kinds ~= #new_block then
		local fallback = {}
		for i = 1, #new_block do
			fallback[i] = "added"
		end
		return fallback
	end
	return kinds
end
return M
