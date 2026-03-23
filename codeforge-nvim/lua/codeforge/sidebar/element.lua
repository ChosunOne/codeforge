local Canvas = require("dapui.render.canvas")
local util = require("dapui.util")
local config = require("dapui.config")

return function()
	local element = {
		allow_without_session = true,
	}

	function element.render()
		local canvas = Canvas.new()
		canvas:write("CodeForge - Pending Review Panel\n")
		canvas:write("\n")
		canvas:write("No pending changes\n")

		canvas:render_buffer(element.buffer(), config.mappings)
	end

	element.buffer = util.create_buffer("CodeForge", {
		filetype = "codeforge",
	})

	return element
end
