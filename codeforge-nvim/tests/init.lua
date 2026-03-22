vim.o.runtimepath = vim.fn.getcwd() .. "," .. vim.o.runtimepath

local mini_path = vim.fn.stdpath("data") .. "/lazy/mini.nvim"
vim.o.runtimepath = vim.o.runtimepath .. "," .. mini_path

require("mini.test").setup()
require("codeforge").setup()
