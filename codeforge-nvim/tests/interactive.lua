-- CodeForge interactive sandbox.
-- Run:  nvim --headless -u tests/init.lua -c "luafile tests/interactive.lua" -c "qa"
--   or:  open nvim, :luafile tests/interactive.lua, then :CodeForge
--
-- Seeds a realistic, wide-gamut change set so you can exercise the full review
-- workflow by hand. Nothing is written to disk: a buffer for the modified file
-- is created in-memory and pre-loaded with CONFLICTING USER EDITS (U) on two of
-- the AI's hunks, so accepting those hunks yields a 3-way merge conflict you
-- can resolve with <C-x>c (then <C-x>o take-ours / <C-x>p take-base / <C-x>f
-- confirm). The other hunks are clean (U == O in their regions) for contrast.

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

-- 1. WHOLE-FILE ADDITION: a brand new module. (No base, no U; clean accept.)
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
-- (status = "deleted", hunks = {} -- nothing to render; sidebar entry only.)

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

-- Pre-load an in-memory buffer for the modified file, named with the SAME
-- relative path the change set uses, and seed it with USER EDITS (U) that
-- CONFLICT with two of the AI's hunks below. buffer.open() will find this
-- buffer (via find_loaded_buf) and snapshot it as U; file.base provides O.
-- Nothing is written to disk.
local service_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(service_buf, "src/net/service.lua")
local service_U = vim.deepcopy(service_base)
-- line 7: user changed to '0.0.0.0'      -> conflicts with hunk-default-host (AI -> '127.0.0.1')
-- line 13: user added a timeout option   -> conflicts with hunk-retry-connect (AI -> retry loop)
service_U[7] = "  self.host = opts.host or '0.0.0.0'"
service_U[13] = "  self.sock = tcp.dial(self.host, self.port, { timeout = 5 })"
vim.api.nvim_buf_set_lines(service_buf, 0, -1, false, service_U)

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
			{
				path = "src/cache/lookup.lua",
				status = "added",
				hunks = { add_file_hunks("hunk-add-cache", new_module) },
			},
			{
				path = "src/legacy/deprecated_api.lua",
				status = "deleted",
				hunks = {},
				decision = "accepted",
			},
			-- (c) Heavily-modified file: many hunks, all shapes.
			--     Two hunks CONFLICT with the pre-loaded U above; the rest are clean.
			{
				path = "src/net/service.lua",
				status = "modified",
				base = service_base,
				hunks = {
					-- CONFLICT: user changed line 7 to '0.0.0.0', AI changed it to '127.0.0.1'.
					-- Accept -> conflicted; resolve with <C-x>c -> <C-x>o (ours) / <C-x>p (base) -> <C-x>f.
					replace_hunk(
						"hunk-default-host",
						7,
						{ "  self.host = opts.host or 'localhost'" },
						{ "  self.host = opts.host or '127.0.0.1'" }
					),

					-- CLEAN: user didn't touch line 9. Accept applies cleanly.
					insert_hunk("hunk-add-port-validation", 9, { "  assert(self.port > 0, 'invalid port')", "" }),

					-- CONFLICT: user changed the dial line to add a timeout option, AI
					-- rewrote it into a retry loop. Both edited the same line vs O.
					replace_hunk("hunk-retry-connect", 13, { "  self.sock = tcp.dial(self.host, self.port)" }, {
						"  for attempt = 1, 3 do",
						"    self.sock = tcp.dial(self.host, self.port)",
						"    if self.sock then break end",
						"    sleep(0.2 * attempt)",
						"  end",
					}),

					-- CLEAN: pure deletion of a line the user didn't touch.
					delete_hunk("hunk-drop-write", 18, { "  self.sock:write(msg)" }),

					-- CLEAN: replace the close() guard; user didn't touch line 22.
					replace_hunk(
						"hunk-close-guard",
						22,
						{ "  if self.sock then" },
						{ "  if self.sock and not self.sock:is_closed() then" }
					),

					-- CLEAN: multi-line replace (3 -> 2+) the user didn't touch.
					replace_hunk("hunk-close-teardown", 23, { "    self.sock:close()", "    self.sock = nil" }, {
						"    pcall(self.sock.close, self.sock)",
						"    self.sock = nil",
						"    metrics.inc('conn.closed')",
					}),
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

-- Build the Review for the modified file DIRECTLY (no buffer.open / show_in_main,
-- so nothing touches a visible window) and pre-mark the two conflicting hunks
-- as `conflicted` by hand. The conflicts are genuine by construction (U edits the
-- same lines the AI changed, so merge3(U[R], O[R], P[R]) conflicts); we just skip
-- the accept step so you can jump straight to <C-x>c (resolve).
--
-- Review:open() snapshots U, builds P into the (unshown) service buffer, and
-- records placements -- it mutates only service_buf, which is not displayed, so
-- your current window is untouched. M.open is idempotent (shows an existing
-- review instead of re-snapshotting), so opening via the sidebar later won't
-- corrupt the pre-set state.
do
	local path = "src/net/service.lua"
	local file = state.get_current_change().files[3] -- src/net/service.lua
	local Review = require("codeforge.review.review")
	local review = Review.new(path, service_buf, file.base, file.hunks)
	review:open()
	review.hunk_status["hunk-default-host"] = "conflicted"
	review.hunk_status["hunk-retry-connect"] = "conflicted"
end

if state._on_change then
	state._on_change()
end
