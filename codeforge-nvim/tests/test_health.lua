local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()

---Run the health check in the child and return the captured output text.
---The module only exists when the plugin is on the runtimepath, so this is
---also the assertion that :checkhealth codeforge will discover it.
---@return string
local function run_health()
	return child.lua_get([[(function()
		local out = {}
		local orig = vim.health
		local health = {
			start = function(msg) out[#out + 1] = "START " .. msg end,
			ok = function(msg) out[#out + 1] = "OK " .. tostring(msg) end,
			warn = function(msg) out[#out + 1] = "WARN " .. tostring(msg) end,
			error = function(msg) out[#out + 1] = "ERROR " .. tostring(msg) end,
			info = function(msg) out[#out + 1] = "INFO " .. tostring(msg) end,
		}
		vim.health = health
		local ok, err = pcall(function()
			require("codeforge.health").check()
		end)
		vim.health = orig
		if not ok then
			out[#out + 1] = "THREW " .. tostring(err)
		end
		return table.concat(out, "\n")
	end)()]])
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
		end,
		post_case = function()
			vim.env.CODEFORGE_TEST_SESSION = nil
		end,
		post_once = child.stop,
	},
})

T["checkhealth discovers the module on the runtimepath"] = function()
	-- This is the discovery contract :checkhealth uses.
	local files = child.lua_get([[vim.api.nvim_get_runtime_file("lua/codeforge/health.lua", false)]])
	MiniTest.expect.equality(#files, 1, {
		fail_reason = "lua/codeforge/health.lua must be discoverable on the rtp",
	})
end

T["the health report names the plugin and starts a section"] = function()
	local out = run_health()
	MiniTest.expect.equality(out:match("^START ") ~= nil, true, { fail_reason = "report=" .. out })
	MiniTest.expect.equality(out:match("codeforge") ~= nil, true, {
		fail_reason = "the report must name the plugin, got " .. out,
	})
	MiniTest.expect.equality(out:match("THREW") == nil, true, {
		fail_reason = "check() must not throw, got " .. out,
	})
end

T["the report reports the git dependency as ok when git works"] = function()
	local out = run_health()
	-- git diff/merge-file drives the whole review merge; a missing git is fatal.
	MiniTest.expect.equality(out:match("git") ~= nil, true, {
		fail_reason = "the report must mention the git dependency, got " .. out,
	})
	local git_line = out:match("[^\n]*[Gg]it[^\n]*")
	MiniTest.expect.equality(git_line ~= nil and git_line:match("^OK") ~= nil, true, {
		fail_reason = "git should be OK in this environment, got " .. tostring(git_line),
	})
end

T["the report reports a missing git as an error, not a crash"] = function()
	-- Force PATH to empty so `git` cannot be found, and confirm we degrade to a
	-- reported error rather than throwing or claiming OK.
	local out = child.lua_get([[(function()
		local original = vim.env.PATH
		vim.env.PATH = ""
		local lines = {}
		vim.health = {
			start = function() end,
			ok = function(m) lines[#lines + 1] = "OK " .. tostring(m) end,
			warn = function(m) lines[#lines + 1] = "WARN " .. tostring(m) end,
			error = function(m) lines[#lines + 1] = "ERROR " .. tostring(m) end,
			info = function() end,
		}
		local ok, err = pcall(function() require("codeforge.health").check() end)
		vim.env.PATH = original
		if not ok then lines[#lines + 1] = "THREW " .. tostring(err) end
		return table.concat(lines, "\n")
	end)()]])
	MiniTest.expect.equality(out:match("THREW") == nil, true, {
		fail_reason = "a missing git must be reported, not thrown, got " .. out,
	})
	MiniTest.expect.equality(out:match("ERROR") ~= nil, true, {
		fail_reason = "a missing git must produce an ERROR, got " .. out,
	})
	MiniTest.expect.equality(out:match("^OK .*[Gg]it") == nil, true, {
		fail_reason = "a missing git must not be reported OK, got " .. out,
	})
end

T["the report surfaces an unreadable session path rather than claiming ok"] = function()
	-- Point session storage at a path whose parent is a regular file, so the
	-- write cannot succeed. The report must warn, not silently pass.
	local tmp = child.fn.tempname()
	child.fn.writefile({ "not a directory" }, tmp)
	child.lua(string.format([[require("codeforge").config.session = %s]], vim.inspect(tmp .. "/session.json")))
	child.lua([[require("codeforge.session").configure(require("codeforge").config.session)]])
	local out = child.lua_get([[(function()
		local lines = {}
		vim.health = {
			start = function() end,
			ok = function(m) lines[#lines + 1] = "OK " .. tostring(m) end,
			warn = function(m) lines[#lines + 1] = "WARN " .. tostring(m) end,
			error = function(m) lines[#lines + 1] = "ERROR " .. tostring(m) end,
			info = function() end,
		}
		pcall(function() require("codeforge.health").check() end)
		return table.concat(lines, "\n")
	end)()]])
	os.remove(tmp)
	MiniTest.expect.equality(out:match("WARN") ~= nil, true, {
		fail_reason = "an unwritable session path must be a WARN, got " .. out,
	})
	MiniTest.expect.equality(out:match("session") ~= nil, true, {
		fail_reason = "the report must name the session path, got " .. out,
	})
end

T["check() is safe to run repeatedly and leaves no global health shim"] = function()
	local before = child.lua_get([[vim.health.start ~= nil]])
	run_health()
	run_health()
	local after = child.lua_get([[vim.health.start ~= nil]])
	MiniTest.expect.equality(before, after)
	MiniTest.expect.equality(after, true, {
		fail_reason = "check() must restore the real vim.health table",
	})
end

return T
