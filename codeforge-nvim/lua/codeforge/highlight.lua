local M = {}

function M.setup()
	vim.api.nvim_set_hl(0, "CodeForgeFile", { link = "Directory" })
	vim.api.nvim_set_hl(0, "CodeForgeStatusAdded", { link = "GitSignsAdd" })
	vim.api.nvim_set_hl(0, "CodeForgeStatusModified", { link = "GitSignsChange" })
	vim.api.nvim_set_hl(0, "CodeForgeStatusDeleted", { link = "GitSignsDelete" })

	vim.api.nvim_set_hl(0, "CodeForgeHunkAdded", { link = "GitSignsAdd" })
	vim.api.nvim_set_hl(0, "CodeForgeHunkModified", { link = "GitSignsChange" })
	vim.api.nvim_set_hl(0, "CodeForgeHunkDeleted", { link = "GitSignsDelete" })
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

return M
