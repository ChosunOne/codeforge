local M = {}

M.config = {
	keymaps = {
		next_change = "<C-]>",
		prev_change = "<C-[>",
	},
}
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
	local element, refresh = require("codeforge.sidebar.element")(M.config)
	dapui.register_element("codeforge", element)
	M.state.set_on_change(refresh)

	vim.api.nvim_create_user_command("CodeForge", function()
		dapui.toggle({ layout = 1 })
		local wins = vim.api.nvim_list_wins()
		for _, win in ipairs(wins) do
			local buf = vim.api.nvim_win_get_buf(win)
			local name = vim.api.nvim_buf_get_name(buf)
			if name:match("CodeForge") then
				vim.api.nvim_set_current_win(win)
				break
			end
		end
	end, { desc = "Toggle CodeForge sidebar" })
end

return M
