local M = {}

M.config = {}

function M.setup(opts)
	opts = opts or {}
	M.config = vim.tbl_extend("force", M.config, opts)

	local dapui = require("dapui")
	local element = require("codeforge.sidebar.element")
	dapui.register_element("codeforge", element())

	dapui.setup({
		layouts = {
			{
				elements = {
					{ id = "codeforge", size = 1.0 },
				},
				size = 40,
				position = "right",
			},
		},
	})

	vim.api.nvim_create_user_command("CodeForge", function()
		dapui.toggle({ layout = 1 })
	end, { desc = "Toggle CodeForge sidebar" })
end

return M
