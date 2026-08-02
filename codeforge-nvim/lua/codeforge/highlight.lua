local M = {}

---Link `name` to `prefer` if that group is defined, else to `fallback`.
---@param name string the CodeForge group to define
---@param prefer string the preferred link target
---@param fallback string the portable fallback
local function link(name, prefer, fallback)
	local defined = not vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = prefer, create = false }))
	vim.api.nvim_set_hl(0, name, { link = defined and prefer or fallback })
end

function M.setup()
	vim.api.nvim_set_hl(0, "CodeForgeFile", { link = "Directory" })
	link("CodeForgeStatusAdded", "GitSignsAdd", "DiffAdd")
	link("CodeForgeStatusModified", "GitSignsChange", "DiffChange")
	link("CodeForgeStatusDeleted", "GitSignsDelete", "DiffDelete")

	link("CodeForgeHunkAdded", "GitSignsAdd", "DiffAdd")
	link("CodeForgeHunkModified", "GitSignsChange", "DiffChange")
	link("CodeForgeHunkDeleted", "GitSignsDelete", "DiffDelete")

	link("CodeForgeReviewAccepted", "GitSignsAdd", "DiffAdd")
	link("CodeForgeReviewRejected", "GitSignsDelete", "DiffDelete")
	link("CodeForgeReviewConflicted", "GitSignsChange", "DiffChange")
	link("CodeForgeReviewModified", "GitSignsChange", "DiffChange")
	vim.api.nvim_set_hl(0, "CodeForgeReviewPending", { link = "Comment" })
end

---@param status string
---@param is_hunk boolean
function M.get_status_hl(status, is_hunk)
	local prefix = is_hunk and "CodeForgeHunk" or "CodeForgeStatus"
	if status == "added" then
		return prefix .. "Added"
	elseif status == "deleted" then
		return prefix .. "Deleted"
	else
		return prefix .. "Modified"
	end
end

---Highlight group for a hunk's review triage status
---@param status string? "accepted"|"rejected"|"conflicted"|nil
---@return string hl_group
function M.get_review_status_hl(status)
	if status == "accepted" then
		return "CodeForgeReviewAccepted"
	elseif status == "rejected" then
		return "CodeForgeReviewRejected"
	elseif status == "conflicted" then
		return "CodeForgeReviewConflicted"
	elseif status == "modified" then
		return "CodeForgeReviewModified"
	end
	return "CodeForgeReviewPending"
end

return M
