local codeforge = require("codeforge")
local state = require("codeforge.state")
-- Setup highlights first (in case main setup hasn't run)
local highlight = require("codeforge.highlight")
highlight.setup()
-- Reset state completely
state.reset()
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
						description = "Optimize SELECT with JOIN",
						old_start = 45,
						old_lines = 8,
						new_start = 45,
						new_lines = 12,
						lines = {},
						status = "modified",
						modified_content = nil,
					},
					{
						id = "hunk-002",
						description = "Add index hints",
						old_start = 120,
						old_lines = 3,
						new_start = 124,
						new_lines = 5,
						lines = {},
						status = "added",
						modified_content = nil,
					},
				},
			},
			{
				path = "src/db/connection.lua",
				status = "modified",
				hunks = {
					{
						id = "hunk-003",
						description = "Fix connection pooling",
						old_start = 15,
						old_lines = 10,
						new_start = 15,
						new_lines = 8,
						lines = {},
						status = "modified",
						modified_content = nil,
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
