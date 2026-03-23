local Canvas = require("dapui.render.canvas")
local util = require("dapui.util")
local config = require("dapui.config")

return function()
	local element = {
		allow_without_session = true,
	}

	local send_ready = util.create_render_loop(function()
		element.render()
	end)

	function element.render()
		local canvas = Canvas.new()
		local state = require("codeforge.state")
		local change = state.get_current_change()

		if change then
			local index = state.get_change_index()
			local total = #state.get_changes()
			canvas:write(string.format("[%d/%d] %s\n", index, total, change.title))
		else
			canvas:write("CodeForge - Pending Review Panel\n")
			canvas:write("\n")
			canvas:write("No pending changes\n")
		end

		canvas:render_buffer(element.buffer(), config.mappings)
	end

	element.buffer = util.create_buffer("CodeForge", {
		filetype = "codeforge",
	})

	return element, send_ready
end
