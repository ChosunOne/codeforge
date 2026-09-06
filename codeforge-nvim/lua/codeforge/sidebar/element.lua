local Canvas = require("dapui.render.canvas")
local util = require("dapui.util")
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
	local actions = require("codeforge.sidebar.actions")

	local row_nodes = {}
	local applied_lhs = {}
	local rendering = false

	local send_ready = util.create_render_loop(function()
		element.render()
	end)

	local function drop_applied()
		if #applied_lhs == 0 then
			return
		end
		local buf = element.buffer()
		if not buf or not vim.api.nvim_buf_is_valid(buf) then
			applied_lhs = {}
			return
		end
		for _, lhs in ipairs(applied_lhs) do
			pcall(vim.keymap.del, "n", lhs, { buffer = buf })
		end
		applied_lhs = {}
	end

	local function setup_keymaps()
		local buf = element.buffer()
		if not buf or not vim.api.nvim_buf_is_valid(buf) then
			return
		end

		local km = u_config.keymaps
		if not km then
			return
		end

		local function map(key, fn, desc)
			if not key then
				return
			end
			vim.keymap.set("n", key, fn, { buffer = buf, silent = true, desc = "CodeForge: " .. desc })
			applied_lhs[#applied_lhs + 1] = key
		end

		map(km.next_change, function()
			state.next_change()
		end, "Next change")
		map(km.prev_change, function()
			state.prev_change()
		end, "Previous change")
		map(km.toggle_file, function()
			local node = row_nodes[vim.fn.line(".")]
			if node and node.kind == "file" then
				actions.toggle_file(node.path)
			end
		end, "Toggle file expansion")
		map(km.open_file, function()
			local node = row_nodes[vim.fn.line(".")]
			if not node then
				return
			end
			if node.kind == "hunk" then
				actions.goto_hunk(node.path, node.hunk_id)
				return
			end
			if node.kind == "file" then
				local change = state.get_current_change()
				for _, file in ipairs(change and change.files or {}) do
					if file.path == node.path then
						if file.status ~= "deleted" then
							actions.open_review(node.path)
						end
						return
					end
				end
			end
		end, "Open review buffer / jump to hunk")
	end

	function element.render()
		rendering = true
		local canvas = Canvas.new()
		local change = state.get_current_change()
		local rows = {}
		local current_line = 1

		local function track(node)
			rows[current_line] = node
			current_line = current_line + 1
		end

		if change then
			local index = state.get_change_index()
			local total = #state.get_changes()
			canvas:write(string.format("[%d/%d] %s\n", index, total, change.title))
			track({ kind = "header" })
			local change_status = state.derive_status(change)
			local glyph, glyph_hl = change_status_glyph(change_status)
			canvas:write(glyph .. " ", { group = glyph_hl })
			canvas:write(change_status .. "\n", { group = glyph_hl })
			track({ kind = "header" })

			if change.files and #change.files > 0 then
				for _, file in ipairs(change.files) do
					local is_expanded = state.is_expanded(file.path)
					local status_upper = file.status:upper():sub(1, 1)

					local fglyph, fglyph_hl = state.file_status_glyph(file)
					canvas:write(fglyph .. " ", { group = fglyph_hl })

					if file.status == "modified" then
						local indicator = is_expanded and "▾" or "▸"
						canvas:write(indicator .. " ")
						canvas:write(file.path .. " ", { group = "CodeForgeFile" })
						local status_hl = require("codeforge.highlight").get_status_hl(file.status, false)
						canvas:write("[" .. status_upper .. "]\n", { group = status_hl })
						track({ kind = "file", path = file.path })

						if is_expanded and file.hunks and #file.hunks > 0 then
							local review = state.get_review(file.path)
							for _, hunk in ipairs(file.hunks) do
								local hunk_status_upper = hunk.status:upper():sub(1, 1)
								canvas:write("      ")
								local hg, hg_hl = status_glyph(review and review.hunk_status[hunk.id])
								canvas:write(hg .. " ", { group = hg_hl })
								local live_row = review and review:hunk_row(hunk.id) or nil
								canvas:write("L" .. (live_row or hunk.new_start) .. " ")
								canvas:write(hunk.description .. " ")
								local status_hl = require("codeforge.highlight").get_status_hl(hunk.status, true)
								canvas:write("[" .. hunk_status_upper .. "]\n", { group = status_hl })
								track({ kind = "hunk", path = file.path, hunk_id = hunk.id })
							end
						end
					else
						canvas:write("  ")
						canvas:write(file.path, { group = "CodeForgeFile" })
						local status_hl = require("codeforge.highlight").get_status_hl(file.status, false)
						canvas:write(" ")
						canvas:write("[" .. status_upper .. "]\n", { group = status_hl })
						track({ kind = "file", path = file.path })
					end
				end
			end
		else
			canvas:write("CodeForge - Pending Review Panel\n")
			track({ kind = "header" })
			canvas:write("\n")
			track({ kind = "blank" })
			canvas:write("No pending changes\n")
			track({ kind = "blank" })
		end

		row_nodes = rows

		local no_keys = {}
		canvas:render_buffer(element.buffer(), {
			expand = no_keys,
			open = no_keys,
			remove = no_keys,
			edit = no_keys,
			repl = no_keys,
			toggle = no_keys,
			watch = no_keys,
		})

		rendering = false
		drop_applied()

		setup_keymaps()
	end

	element.buffer = util.create_buffer("CodeForge", {
		filetype = "codeforge",
	})

	return element, send_ready
end
