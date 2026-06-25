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
require("codeforge").setup()
