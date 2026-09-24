-- CodeForge: review AI proposals hunk by hunk in the real file buffer.
--
-- This file exists so `require('codeforge').setup()` is optional. It is
-- sourced on every startup (after init.lua), so an explicit user setup() has
-- already run by the time we act -- and then we do nothing. Otherwise we
-- initialize once with `vim.g.codeforge_setup`, which may be a table of
-- options or `false` to opt out entirely.

if vim.g.loaded_codeforge then
	return
end
vim.g.loaded_codeforge = true

-- Defer to VimEnter: sourcing happens before the user's config finishes in
-- some setups, and VimEnter is late enough that any setup() the user did call
-- has run and left _initialized set.
local function initialize()
	local codeforge = require("codeforge")
	if codeforge._initialized then
		return
	end
	local opts = vim.g.codeforge_setup
	if opts == false then
		return
	end
	codeforge.setup(type(opts) == "table" and opts or {})
end

vim.api.nvim_create_autocmd("VimEnter", {
	group = vim.api.nvim_create_augroup("codeforge_bootstrap", { clear = true }),
	once = true,
	callback = initialize,
})

-- A lazy loader sources plugin files after VimEnter, so the autocmd above
-- would never fire. If we are already past VimEnter, initialize now.
if vim.v.vim_did_enter == 1 then
	initialize()
end
