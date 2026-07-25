-- CodeForge interactive sandbox.
-- Run:  nvim --headless -u tests/init.lua -c "luafile tests/interactive.lua" -c "qa"
--   or:  open nvim, :luafile tests/interactive.lua, then :CodeForge
--
-- This seeds a realistic, wide-gamut change set so you can exercise the full
-- review workflow by hand: whole-file additions, whole-file deletions, files
-- with many hunks (insertions, deletions, replaces, multi-line, overlapping
-- regions, line-content-only tweaks). It is the manual sandbox the automated
-- tests can't fully replace.

local codeforge = require("codeforge")
local state = require("codeforge.state")
local highlight = require("codeforge.highlight")
highlight.setup()
state.reset()

---------------------------------------------------------------------------
-- hunk builder helpers (the format Review:apply_hunks expects):
--   lines = { "-old", "+new", ... }  (no context lines)
--   old_lines = #removed, new_lines = #added
---------------------------------------------------------------------------
local function plus_lines(lines)
	local out = {}
	for i, l in ipairs(lines) do
		out[i] = "+" .. l
	end
	return out
end

local function replace_hunk(id, at, removed, added)
	local lines = {}
	for _, l in ipairs(removed) do
		lines[#lines + 1] = "-" .. l
	end
	for _, l in ipairs(added) do
		lines[#lines + 1] = "+" .. l
	end
	return {
		id = id,
		description = id,
		old_start = at,
		old_lines = #removed,
		new_start = at,
		new_lines = #added,
		lines = lines,
		status = "modified",
	}
end

local function delete_hunk(id, at, removed)
	local lines = {}
	for _, l in ipairs(removed) do
		lines[#lines + 1] = "-" .. l
	end
	return {
		id = id,
		description = id,
		old_start = at,
		old_lines = #removed,
		new_start = at,
		new_lines = 0,
		lines = lines,
		status = "deleted",
	}
end

local function insert_hunk(id, at, added)
	return {
		id = id,
		description = id,
		old_start = at,
		old_lines = 0,
		new_start = at,
		new_lines = #added,
		lines = plus_lines(added),
		status = "added",
	}
end

local function add_file_hunks(id, content)
	-- whole-file addition: one pure-insertion hunk of the entire new content
	return {
		id = id,
		description = id,
		old_start = 1,
		old_lines = 0,
		new_start = 1,
		new_lines = #content,
		lines = plus_lines(content),
		status = "added",
	}
end

---------------------------------------------------------------------------
-- File contents (O = base the AI diffed against; for added files, no base)
---------------------------------------------------------------------------

-- 1. WHOLE-FILE ADDITION: a brand new module.
local new_module = {
	"local M = {}",
	"",
	"---Query the cache before hitting the database.",
	"---@param key string",
	"---@return any|nil",
	"function M.get(key)",
	"  local hit = cache[key]",
	"  if hit ~= nil then",
	"    return hit",
	"  end",
	"  return nil",
	"end",
	"",
	"return M",
}

-- 2. WHOLE-FILE DELETION: an obsolete file removed entirely.
-- (status = "deleted", hunks = {} -- nothing to render.)

-- 3. HEAVILY-MODIFIED FILE with many hunks of different shapes.
local service_base = {
	-- 1
	"local Service = {}",
	-- 2
	"",
	-- 3
	"Service.__index = Service",
	-- 4
	"",
	-- 5
	"function Service:new(opts)",
	-- 6
	"  local self = setmetatable({}, Service)",
	-- 7
	"  self.host = opts.host or 'localhost'",
	-- 8
	"  self.port = opts.port or 5432",
	-- 9
	"  return self",
	-- 10
	"end",
	-- 11
	"",
	-- 12
	"function Service:connect()",
	-- 13
	"  self.sock = tcp.dial(self.host, self.port)",
	-- 14
	"  return self.sock",
	-- 15
	"end",
	-- 16
	"",
	-- 17
	"function Service:send(msg)",
	-- 18
	"  self.sock:write(msg)",
	-- 19
	"end",
	-- 20
	"",
	-- 21
	"function Service:close()",
	-- 22
	"  if self.sock then",
	-- 23
	"    self.sock:close()",
	-- 24
	"    self.sock = nil",
	-- 25
	"  end",
	-- 26
	"end",
	-- 27
	"",
	-- 28
	"return Service",
}

---------------------------------------------------------------------------
-- Assemble the change set
---------------------------------------------------------------------------
local test_changes = {
	{
		id = "change-sandbox",
		title = "Sandbox refactor: caching, retry, telemetry",
		timestamp = os.time() - 3600,
		status = "pending",
		files = {
			-- (a) Whole-file addition.
			{
				path = "src/cache/lookup.lua",
				status = "added",
				hunks = { add_file_hunks("hunk-add-cache", new_module) },
			},
			-- (b) Whole-file deletion.
			{
				path = "src/legacy/deprecated_api.lua",
				status = "deleted",
				hunks = {},
			},
			-- (c) Heavily-modified file: many hunks, all shapes.
			{
				path = "src/net/service.lua",
				status = "modified",
				base = service_base,
				hunks = {
					-- line-content-only tweak (1 line -> 1 line, same length)
					replace_hunk(
						"hunk-default-host",
						7,
						{ "  self.host = opts.host or 'localhost'" },
						{ "  self.host = opts.host or '127.0.0.1'" }
					),

					-- pure insertion of a new field (0 removed -> 2 added)
					insert_hunk("hunk-add-port-validation", 9, { "  assert(self.port > 0, 'invalid port')", "" }),

					-- multi-line replace: rewrite connect() to add retry
					replace_hunk("hunk-retry-connect", 13, { "  self.sock = tcp.dial(self.host, self.port)" }, {
						"  for attempt = 1, 3 do",
						"    self.sock = tcp.dial(self.host, self.port)",
						"    if self.sock then break end",
						"    sleep(0.2 * attempt)",
						"  end",
					}),

					-- pure deletion: drop the send() body line (mark for review)
					delete_hunk("hunk-drop-write", 18, { "  self.sock:write(msg)" }),

					-- overlapping-ish adjacent change: replace close() guard
					replace_hunk(
						"hunk-close-guard",
						22,
						{ "  if self.sock then" },
						{ "  if self.sock and not self.sock:is_closed() then" }
					),

					-- multi-line replace that also changes length (3 -> 2)
					replace_hunk(
						"hunk-close-teardown",
						23,
						{ "    self.sock:close()", "    self.sock = nil" },
						{
							"    pcall(self.sock.close, self.sock)",
							"    self.sock = nil",
							"    metrics.inc('conn.closed')",
						}
					),
				},
			},
		},
	},
}

state.changes = test_changes
state.current_change_index = 1
state.current_change_id = test_changes[1].id

-- Expand the modified file so the sidebar shows its hunks immediately.
state.expanded_files["change-sandbox"] = {
	["src/net/service.lua"] = true,
}

if state._on_change then
	state._on_change()
end
