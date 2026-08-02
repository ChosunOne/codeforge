local Canvas = require("dapui.render.canvas")
local util = require("dapui.util")
local config = require("dapui.config")
local highlight = require("codeforge.highlight")

---Glyph + highlight group for a hunk's review triage status
---@param status string? "accepted"|"rejected"|"conflicted"|nil
---@return string glyph
---@return string hl_group
local function status_glyph(status)
	if status == "accepted" or status == "rejected" then
		return "●", highlight.get_review_status_hl(status)
	elseif status == "conflicted" then
		return "◐", highlight.get_review_status_hl(status)
	end
	return "○", highlight.get_review_status_hl(nil)
end

---Glyph + highlight group for a change's derived review status
---@param status string "pending"|"accepted"|"rejected"|"modified"
---@return string glyph
---@return string hl_group
local function change_status_glyph(status)
	if status == "accepted" or status == "rejected" then
		return "●", highlight.get_review_status_hl(status)
	elseif status == "modified" then
		return "◐", highlight.get_review_status_hl(status)
	end
	return "○", highlight.get_review_status_hl(nil)
end

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
			canvas:write(string.format("[%d/%d] %s\n", index, total, change.title))
			local change_status = state.derive_status(change)
			local glyph, glyph_hl = change_status_glyph(change_status)
			canvas:write(glyph .. " ", { group = glyph_hl })
			canvas:write(change_status .. "\n", { group = glyph_hl })
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

						canvas:add_mapping("expand", function()
							require("codeforge.review.buffer").open(file.path)
						end, { line = current_line })

						current_line = current_line + 1

						if is_expanded and file.hunks and #file.hunks > 0 then
							local review = state.get_review(file.path)
							for _, hunk in ipairs(file.hunks) do
								local hunk_status_upper = hunk.status:upper():sub(1, 1)
								canvas:write("    ")
								local glyph, glyph_hl = status_glyph(review and review.hunk_status[hunk.id])
								canvas:write(glyph .. " ", { group = glyph_hl })
								local live_row = review and review:hunk_row(hunk.id) or nil
								canvas:write("L" .. (live_row or hunk.new_start) .. " ")
								canvas:write(hunk.description .. " ")
								local status_hl = require("codeforge.highlight").get_status_hl(hunk.status, true)
								canvas:write("[" .. hunk_status_upper .. "]\n", { group = status_hl })
								local hunk_id = hunk.id
								canvas:add_mapping("expand", function()
									local sidebar_win = vim.api.nvim_get_current_win()
									local buffer = require("codeforge.review.buffer")
									local review = state.get_review(file.path)
									if not review then
										buffer.open(file.path)
										review = state.get_review(file.path)
									else
										buffer.show_review(file.path)
									end
									if review then
										local row = review:hunk_row(hunk_id)
										if row then
											local win = buffer.win_for_buf(review.buf)
											if win then
												vim.api.nvim_win_set_cursor(win, { row, 0 })
												vim.api.nvim_win_call(win, function()
													vim.cmd("normal! zz")
												end)
											end
										end
									end
									vim.api.nvim_set_current_win(sidebar_win)
								end, { line = current_line })
								current_line = current_line + 1
							end
						end
					else
						canvas:write("  ")
						canvas:write(file.path, { group = "CodeForgeFile" })
						local status_hl = require("codeforge.highlight").get_status_hl(file.status, false)
						canvas:write(" ")
						canvas:write("[" .. status_upper .. "]\n", { group = status_hl })
						canvas:add_mapping("expand", function()
							require("codeforge.review.buffer").open(file.path)
						end, { line = current_line })
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
