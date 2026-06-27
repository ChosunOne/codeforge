local MiniTest = require("mini.test")

---@class ExtmarkDetails
---@field virt_lines table[][]?
---@field hl_group string?
---@field sign_hl_group string?
---@field sign_text string?

---@class Extmark
---@field [1] integer id
---@field [2] integer start_row 0-indexed
---@field [3] integer start_col 0-indexed
---@field [4] ExtmarkDetails details

---@class ChildQuery
local M = {}
local child ---@type MiniTest.child

---Bind this query module to a mini.test child
---@param c MiniTest.child
function M.set_child(c)
	child = c
end

---Find a buffer whose name equals `path` or nil.
---@param path string
---@return integer|nil bufnr
function M.find_buf(path)
	for _, b in ipairs(child.api.nvim_list_bufs()) do
		if child.api.nvim_buf_get_name(b) == path then
			return b
		end
	end
	return nil
end

---Deep equality assertion for a list of lines.
---@param name string label for failure messages
---@param got string[]
---@param want string[]
function M.expect_lines(name, got, want)
	MiniTest.expect.equality(
		vim.deep_equal(got, want),
		true,
		{ fail_reason = name .. ": got " .. vim.inspect(got) .. ", want " .. vim.inspect(want) }
	)
end

---All extmarks in `buf` / `ns` with details.
---@param buf integer
---@param ns integer
---@return Extmark[] marks
function M.extmarks(buf, ns)
	return child.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

---All extmarks anchored at the exact (0-indexed) `row`/`col`, with details.
---@param buf integer
---@param ns integer
---@param row integer 0-indexed line
---@param col integer 0-indexed column
---@return Extmark[] marks
function M.extmarks_at(buf, ns, row, col)
	local out = {}
	for _, m in ipairs(M.extmarks(buf, ns)) do
		if m[2] == row and m[3] == col then
			out[#out + 1] = m
		end
	end
	return out
end

---@param buf integer
---@param ns integer
---@param row integer 0-indexed line
---@return ExtmarkDetails?
function M.hl_at(buf, ns, row)
	for _, m in ipairs(M.extmarks_at(buf, ns, row, 0)) do
		if m[4] and m[4].hl_group then
			return m[4]
		end
	end
	return nil
end

---@param buf integer
---@param ns integer
---@param row integer
---@return ExtmarkDetails?
function M.fold_at(buf, ns, row)
	for _, m in ipairs(M.extmarks_at(buf, ns, row, 0)) do
		if m[4] and m[4].virt_lines then
			return m[4]
		end
	end
	return nil
end

---True if any extmark carries a virt_lines block whose joined
---text contains `needle`
---@param buf integer
---@param ns integer
---@param needle string
---@return boolean found
---@return integer|nil id extmark id when found
function M.has_virt_line_containing(buf, ns, needle)
	for _, m in ipairs(M.extmarks(buf, ns)) do
		local details = m[4]
		if details and details.virt_lines then
			for _, vline in ipairs(details.virt_lines) do
				local text = ""
				for _, chunk in ipairs(vline) do
					text = text .. (chunk[1] or "")
				end
				if text:find(needle, 1, true) then
					return true, m[1]
				end
			end
		end
	end
	return false
end

---True if any extmark has hl_group == `group`
---@param buf integer
---@param ns integer
---@param group string highlight group name
---@return boolean found
---@return integer|nil id
---@return integer|nil row 0-indexed
function M.has_hl_group(buf, ns, group)
	for _, m in ipairs(M.extmarks(buf, ns)) do
		local d = m[4]
		if d and d.hl_group == group then
			return true, m[1], m[2]
		end
	end
	return false
end

---True if any extmark has sign_hl_group == `group`
---@param buf integer
---@param ns integer
---@param group? string highlight group name, or nil for "any sign"
---@return boolean found
---@return integer|nil id
function M.has_sign(buf, ns, group)
	for _, m in ipairs(M.extmarks(buf, ns)) do
		local d = m[4]
		if d and (d.sign_hl_group == group or (group == nil and d.sign_text ~= nil)) then
			return true, m[1]
		end
	end
	return false
end

return M
