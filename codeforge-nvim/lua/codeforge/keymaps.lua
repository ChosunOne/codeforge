---Announce buffer-local keymap changes to the wider editor.
---
---Neovim has no autocmd event for "keymaps changed". External consumers that
---cache a buffer's local mappings (which-key being the common one) refresh
---that cache on the standard buffer-load events. Emitting `BufReadPost` after
---we install or remove our buffer-local maps is therefore how we make those
---consumers pick the change up, without depending on any of them: we fire a
---plain, documented editor event and let whoever is interested react.
---
---`modeline = false` keeps the emission to a plain re-read signal, so no
---modeline processing is triggered; the buffer's contents, 'filetype',
---changedtick, and undo history are untouched.
local M = {}

---Emit `BufReadPost` for `buf` so mapping caches are rebuilt.
---No-op for an invalid buffer.
---@param buf integer?
function M.announce(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_buf_call(buf, function()
		vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf, modeline = false })
	end)
end

return M
