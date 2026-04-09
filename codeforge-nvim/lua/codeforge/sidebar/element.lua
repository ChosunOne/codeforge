local Canvas = require("dapui.render.canvas")
local util = require("dapui.util")
local config = require("dapui.config")

return function(user_config)
	local element = {
		allow_without_session = true,
	}

	local u_config = user_config or {}

	local state = require("codeforge.state")

	local send_ready = util.create_render_loop(function()
		element.render()
	end)

	local function setup_keymaps()
		local buf = element.buffer()
		if not buf or not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		if u_config.keymaps and u_config.keymaps.next_change then
			vim.keymap.set("n", u_config.keymaps.next_change, function()
				state.next_change()
			end, {
				buf = buf,
				silent = true,
				desc = "CodeForge: Next change",
			})
			vim.keymap.set("n", u_config.keymaps.prev_change, function()
				state.prev_change()
			end, {
				buf = buf,
				silent = true,
				desc = "CodeForge: Previous change",
			})
		end
	end

	function element.render()
		local canvas = Canvas.new()
		local change = state.get_current_change()

		if change then
			local index = state.get_change_index()
			local total = #state.get_changes()
			canvas:write(string.format("[%d/%d] %s\n\n", index, total, change.title))
			local current_line = 3

			if change.files and #change.files > 0 then
				for _, file in ipairs(change.files) do
					local is_modified = file.status == "modified"
					local is_expanded = state.is_expanded(file.path)
					local status_upper = file.status:upper():sub(1, 1)

					if is_modified then
						local indicator = is_expanded and "▾" or "▸"
						canvas:write(indicator .. " ")
						canvas:write(file.path .. " ", { group = "CodeForgeFile" })
						local status_hl = require("codeforge.highlight").get_status_hl(file.status, false)
						canvas:write("[" .. status_upper .. "]\n", { group = status_hl })
						canvas:add_mapping("open", function()
							state.toggle_file(file.path)
						end, { line = current_line })

						current_line = current_line + 1

						if is_expanded and file.hunks and #file.hunks > 0 then
							for _, hunk in ipairs(file.hunks) do
								local hunk_status_upper = hunk.status:upper():sub(1, 1)
								canvas:write("    ")
								canvas:write("L" .. hunk.new_start .. " ")
								canvas:write(hunk.description .. " ")
								local status_hl = require("codeforge.highlight").get_status_hl(hunk.status, true)
								canvas:write("[" .. hunk_status_upper .. "]\n", { group = status_hl })
								current_line = current_line + 1
							end
						end
					else
						canvas:write("  ")
						canvas:write(file.path, { group = "CodeForgeFile" })
						local status_hl = require("codeforge.highlight").get_status_hl(file.status, false)
						canvas:write(" ")
						canvas:write("[" .. status_upper .. "]\n", { group = status_hl })
						current_line = current_line + 1
					end
				end
			end
		else
			canvas:write("CodeForge - Pending Review Panel\n")
			canvas:write("\n")
			canvas:write("No pending changes\n")
		end

		canvas:render_buffer(element.buffer(), config.element_mapping("codeforge"))

		setup_keymaps()
	end

	element.buffer = util.create_buffer("CodeForge", {
		filetype = "codeforge",
	})

	return element, send_ready
end
