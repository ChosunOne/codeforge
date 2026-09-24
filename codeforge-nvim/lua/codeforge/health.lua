-- :checkhealth codeforge
--
-- Reports the environment facts a CodeForge bug report needs: the git binary
-- the merge engine shells out to, the socket address clients publish to, and
-- the session/log files whose contents decide whether a restart restores a
-- review. Read-only: it never starts the socket, opens a buffer, or writes a
-- session.

local M = {}

---Is `git` runnable? The review merge is `git diff`/`git merge-file`, so this
---is a hard requirement, not an optional nicety.
---@return boolean ok
---@return string detail
local function git_check()
	local exe = vim.fn.exepath("git")
	if exe == "" or exe == nil then
		return false, "git not found on PATH"
	end
	local out = vim.fn.system({ "git", "--version" })
	if vim.v.shell_error ~= 0 then
		return false, string.format("%s exists but `git --version` failed: %s", exe, vim.trim(out))
	end
	return true, string.format("%s (%s)", exe, vim.trim(out))
end

---Describe the configured socket without starting one.
---@return string
local function socket_summary()
	local transport = require("codeforge.transport")
	local active = transport.active_socket
	local path = transport.socket_path()
	if type(active) == "string" then
		return string.format("listening on %s", active)
	end
	local config = require("codeforge").config
	if config.socket == false then
		return "disabled by configuration"
	end
	return string.format("not running (would listen on %s)", path)
end

---A file is "writable" if its parent directory exists and is writable, or can
---be created. We do not create anything here; we only report.
---@param path string
---@return boolean ok
---@return string detail
local function path_writable(path)
	local dir = vim.fs.dirname(path)
	if vim.fn.getftype(dir) == "file" or vim.fn.getftype(dir) == "link" then
		-- The parent exists but is not a directory; nothing can be written here.
		return false, string.format("%s is not a directory", dir)
	end
	if vim.fn.isdirectory(dir) == 1 then
		if vim.fn.filewritable(dir) == 2 then
			return true, "writable"
		end
		return false, string.format("directory %s is not writable", dir)
	end
	local parent = vim.fs.dirname(dir)
	if vim.fn.isdirectory(parent) == 1 and vim.fn.filewritable(parent) == 2 then
		return true, string.format("will create %s", dir)
	end
	return false, string.format("cannot create directory %s", dir)
end

---@return nil
function M.check()
	vim.health.start("codeforge")

	local ok, detail = git_check()
	if ok then
		vim.health.ok("git: " .. detail)
	else
		vim.health.error("git: " .. detail, { "Install git; the review merge shells out to it." })
	end

	local version = vim.version()
	vim.health.info(string.format("Neovim: %s", tostring(version)))

	local require_ok, _ = pcall(require, "dapui")
	if require_ok then
		vim.health.ok("sidebar dependency `dapui` is available")
	else
		vim.health.error("sidebar dependency `dapui` is missing", { "Install nvim-dap-ui." })
	end

	local init_ok = pcall(require, "codeforge")
	if init_ok and require("codeforge")._initialized then
		vim.health.ok("initialized")
	else
		vim.health.warn("not initialized", { "Call require('codeforge').setup() or rely on auto-setup." })
	end

	local socket_ok, socket_detail = pcall(socket_summary)
	if socket_ok then
		vim.health.info("socket: " .. socket_detail)
	else
		vim.health.warn("socket: unavailable (" .. tostring(socket_detail) .. ")")
	end

	local state = require("codeforge.state")
	if type(state.log_file) == "string" then
		local log_ok, log_detail = path_writable(state.log_file)
		if log_ok then
			vim.health.info(string.format("decision log: %s (%s)", state.log_file, log_detail))
		else
			vim.health.warn(string.format("decision log: %s (%s)", state.log_file, log_detail))
		end
	else
		vim.health.warn("decision log: no path configured")
	end

	local session = require("codeforge.session")
	local config = require("codeforge").config
	if config.session == false or not session.enabled() then
		vim.health.info("session persistence: disabled")
	else
		local path = session.path()
		local session_ok, session_detail = path_writable(path)
		if session_ok then
			vim.health.info(string.format("session: %s (%s)", path, session_detail))
		else
			vim.health.warn(string.format("session: %s (%s)", path, session_detail))
		end
	end
end

return M
