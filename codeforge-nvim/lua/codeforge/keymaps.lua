local M = {}
---Refresh which-key v3 after changing buffer-local normal-mode mappings.
---This integration is optional: never load which-key on the user's behalf.
---
---Do not fake BufReadPost here. Besides replaying unrelated file-load hooks,
---it clears which-key's Mode while a trigger update for that Mode may still
---be queued. The stale update can then remove the new Mode's Ctrl-x trigger,
---even though the new mapping tree correctly lists all our shortcuts.
---Updating the existing Mode in place keeps queued trigger work consistent.
---@param buf integer?
function M.announce(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local config = package.loaded["which-key.config"]
	local buffers = package.loaded["which-key.buf"]
	if type(config) ~= "table" or not rawget(config, "loaded") then
		return
	end
	if type(buffers) == "table" and type(buffers.get) == "function" then
		buffers.get({ buf = buf, mode = "n", update = true })
	end
end

return M
