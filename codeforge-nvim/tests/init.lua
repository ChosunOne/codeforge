vim.o.runtimepath = vim.fn.getcwd() .. "," .. vim.o.runtimepath

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
