local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.resolve(this), ":p:h:h")
vim.o.runtimepath = root .. "," .. vim.o.runtimepath

package.path = root .. "/tests/?.lua;" .. package.path

local mini_path = vim.fn.stdpath("data") .. "/lazy/mini.nvim"
local dapui_path = vim.fn.stdpath("data") .. "/lazy/nvim-dap-ui"
local nvim_dap_path = vim.fn.stdpath("data") .. "/lazy/nvim-dap"
local nio_path = vim.fn.stdpath("data") .. "/lazy/nvim-nio"
vim.o.runtimepath = vim.o.runtimepath
	.. ","
	.. mini_path
	.. ","
	.. dapui_path
	.. ","
	.. nvim_dap_path
	.. ","
	.. nio_path

require("mini.test").setup()
-- Tests own their change sets: a real session file must never leak between runs
-- or restore changes a test did not seed. A test that needs the real setup()
-- wiring points CODEFORGE_TEST_SESSION at its own file and restarts.
--
-- CODEFORGE_TEST_NO_SETUP=1 skips this call so plugin/codeforge.lua's own
-- auto-initialization is the only thing that can run setup() (test_autoload).
if vim.env.CODEFORGE_TEST_NO_SETUP ~= "1" then
	require("codeforge").setup({ socket = false, session = vim.env.CODEFORGE_TEST_SESSION or false })
end
