local codeforge = require("codeforge")
local state = require("codeforge.state")
-- Setup highlights first (in case main setup hasn't run)
local highlight = require("codeforge.highlight")
highlight.setup()
-- Reset state completely
state.reset()

-- Realistic file contents. Hunks use jj diff format lines: " " context,
-- "-" removed, "+" added. `base` is the file content the AI diffed against
-- (the O in O/P/U); for added files it is nil/empty.

-- src/db/queries.lua  (added) -- whole file is additions
local queries_new = {
	"local M = {}",
	"",
	"---Run a SELECT with an explicit JOIN plan.",
	"---@param db table",
	"---@param sql string",
	"---@param params table",
	"---@return table[] rows",
	"function M.select_join(db, sql, params)",
	"  db:exec([[SET enable_nestloop = off]])",
	"  local rows = db:query(sql, params)",
	"  return rows",
	"end",
	"",
	"return M",
}

-- src/db/connection.lua  (modified) -- base is the pre-edit version (O).
-- Hunk replaces base line 7 (the timeout execute) with the fix + a pool
-- assignment. Format: no context lines, just "-" removed + "+" added.
local connection_base = {
	"local M = {}",
	"",
	"local pool = {}",
	"",
	"function M.connect(opts)",
	"  local conn = rawconnect(opts)",
	"  conn:execute([[SET timeout = 5000]])",
	"  return conn",
	"end",
	"",
	"function M.disconnect(conn)",
	"  conn:close()",
	"  pool[conn] = nil",
	"end",
	"",
	"return M",
}
local connection_removed = { "  conn:execute([[SET timeout = 5000]])" }
local connection_added = {
	"  conn:execute([[SET statement_timeout = 5000]])",
	"  pool[conn] = true",
}

-- Create sample changes with various statuses
local test_changes = {
	{
		id = "change-002",
		title = "Refactor database queries",
		timestamp = os.time() - 3600,
		status = "pending",
		files = {
			{
				path = "src/db/queries.lua",
				status = "added",
				hunks = {
					{
						id = "hunk-001",
						description = "Add select_join helper",
						old_start = 1,
						old_lines = 0,
						new_start = 1,
						new_lines = #queries_new,
						lines = (function()
							local l = {}
							for i, line in ipairs(queries_new) do
								l[i] = "+" .. line
							end
							return l
						end)(),
						status = "added",
					},
				},
			},
			{
				path = "src/db/connection.lua",
				status = "modified",
				base = connection_base,
				hunks = {
					{
						id = "hunk-003",
						description = "Fix connection pooling",
						old_start = 7,
						old_lines = #connection_removed,
						new_start = 7,
						new_lines = #connection_added,
						lines = (function()
							local l = {}
							for _, x in ipairs(connection_removed) do
								l[#l + 1] = "-" .. x
							end
							for _, x in ipairs(connection_added) do
								l[#l + 1] = "+" .. x
							end
							return l
						end)(),
						status = "modified",
					},
				},
			},
		},
	},
	{
		id = "change-003",
		title = "Remove deprecated API endpoints",
		timestamp = os.time() - 7200,
		status = "pending",
		files = {
			{
				path = "src/api/legacy.lua",
				status = "deleted",
				hunks = {},
			},
			{
				path = "src/api/old_helpers.lua",
				status = "deleted",
				hunks = {},
			},
		},
	},
}
-- Load test data into state
state.changes = test_changes
state.current_change_index = 1
state.current_change_id = test_changes[1].id
-- Expand the first modified file to show hunks
state.expanded_files["change-002"] = {
	["src/db/queries.lua"] = true,
}
-- Trigger refresh
if state._on_change then
	state._on_change()
end
