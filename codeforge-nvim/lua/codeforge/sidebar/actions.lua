local M = {}

---@param path string file path within the current change
function M.toggle_file(path)
	local state = require("codeforge.state")
	local change = state.get_current_change()
	if not change then
		return
	end

	for _, file in ipairs(change.files or {}) do
		if file.path == path then
			if file.status == "modified" then
				state.toggle_file(path)
			else
				file.decision = file.decision == "accepted" and "rejected" or "accepted"
				state.notify_change()
			end
			return
		end
	end
end

---Open (or focus) the review buffer for a file.
---@param path string
function M.open_review(path)
	require("codeforge.review.buffer").open(path)
end

---Open the review for `path` and place the cursor on `hunk_id`, keeping
---focus in the sidebar window it was invoked from.
---@param path string
---@param hunk_id string
function M.goto_hunk(path, hunk_id)
	local state = require("codeforge.state")
	local sidebar_win = vim.api.nvim_get_current_win()
	local buffer = require("codeforge.review.buffer")
	local review = state.get_review(path)
	if not review then
		buffer.open(path)
		review = state.get_review(path)
	else
		buffer.show_review(path)
	end
	if review then
		local row = review:hunk_row(hunk_id)
		if row then
			local win = buffer.win_for_buf(review.buf)
			if win then
				vim.api.nvim_win_set_cursor(win, { row, 0 })
				vim.api.nvim_win_call(win, function()
					vim.cmd("normal! zz")
				end)
			end
		end
	end
	if vim.api.nvim_win_is_valid(sidebar_win) then
		vim.api.nvim_set_current_win(sidebar_win)
	end
end

return M
