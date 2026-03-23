local M = {}

M.config = {}
M._initialized = false

function M.setup(opts)
	if M._initialized then
		return
	end
	M._initialized = true
	opts = opts or {}
	M.config = vim.tbl_extend("force", M.config, opts)
	M.state = require("codeforge.state")

	local dapui = require("dapui")
	local element, refresh = require("codeforge.sidebar.element")()
	dapui.register_element("codeforge", element)
	M.state.set_on_change(refresh)

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
