local M = {}

function M.setup()
	vim.api.nvim_set_hl(0, "CodeForgeFile", { link = "Directory" })
	vim.api.nvim_set_hl(0, "CodeForgeStatusAdded", { link = "DiffAdd" })
	vim.api.nvim_set_hl(0, "CodeForgeStatusModified", { link = "DiffChange" })
	vim.api.nvim_set_hl(0, "CodeForgeStatusDeleted", { link = "DiffDelete" })

	vim.api.nvim_set_hl(0, "CodeForgeHunkAdded", { link = "DiffAdd" })
	vim.api.nvim_set_hl(0, "CodeForgeHunkModified", { link = "DiffChange" })
	vim.api.nvim_set_hl(0, "CodeForgeHunkDeleted", { link = "DiffDelete" })
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
