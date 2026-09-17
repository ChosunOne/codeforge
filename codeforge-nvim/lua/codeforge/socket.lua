---Bounded, one-request-per-connection JSON socket. This is NOT Neovim RPC.
local uv = vim.uv
local protocol = require("codeforge.protocol")
local M = {}

local function close_handle(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

-- libuv may return nil,error rather than throwing; handle both forms.
local function checked(fn, ...)
	local ok, value, err = pcall(fn, ...)
	if not ok then
		return nil, tostring(value)
	end
	if value == nil or value == false then
		return nil, tostring(err)
	end
	return value
end

local function group_id(name)
	local ok, lines = pcall(vim.fn.readfile, "/etc/group")
	if not ok then
		return nil
	end
	for _, line in ipairs(lines) do
		local group, gid = line:match("^([^:]+):[^:]*:(%d+):")
		if group == name then
			return tonumber(gid)
		end
	end
end

local function options(opt, windows)
	local limits = { max_message_bytes = 1024 * 1024, max_clients = 16, request_timeout_ms = 5000 }
	local ceilings = { max_message_bytes = 1024 * 1024, max_clients = 128, request_timeout_ms = 60000 }
	for key, default in pairs(limits) do
		local value = opt[key] == nil and default or opt[key]
		if type(value) ~= "number" or value < 1 or value > ceilings[key] or value ~= math.floor(value) then
			return nil, key .. " must be an integer between 1 and " .. ceilings[key]
		end
		limits[key] = value
	end
	for key in pairs(opt) do
		if key ~= "path" and key ~= "mode" and key ~= "group" and limits[key] == nil then
			return nil, "unknown socket option: " .. tostring(key)
		end
	end
	if windows and (opt.mode ~= nil or opt.group ~= nil) then
		return nil, "socket group/mode cannot be enforced on Windows named pipes"
	end
	limits.mode = tonumber("600", 8)
	if opt.mode ~= nil then
		if type(opt.mode) ~= "string" or not opt.mode:match("^0?[0-7][0-7][0-7]$") then
			return nil, "socket mode must be a three-digit octal string (optional leading zero)"
		end
		limits.mode = tonumber(opt.mode, 8)
	end
	if opt.group ~= nil then
		if type(opt.group) ~= "string" then
			return nil, "socket group must be a name"
		end
		limits.gid = group_id(opt.group)
		if not limits.gid then
			return nil, "socket group not found: " .. opt.group
		end
	end
	return limits
end

function M.start(path, opt, windows)
	local limits, err = options(opt, windows)
	if not limits then
		return nil, err
	end
	local self = { path = path, clients = {}, count = 0, closed = false }
	local listener = uv.new_pipe(false)
	self.listener = listener

	local function close_client(client)
		if client.closed then
			return
		end
		client.closed = true
		self.clients[client] = nil
		self.count = self.count - 1
		client.buffer = nil
		close_handle(client.timer)
		close_handle(client.pipe)
	end

	function self:stop()
		if self.closed then
			return
		end
		self.closed = true
		for client in pairs(self.clients) do
			close_client(client)
		end
		close_handle(listener)
		-- Never remove someone else's replacement path or an unowned stale file.
		if self.identity and not windows then
			local st = uv.fs_lstat(path)
			if st and st.type == "socket" and st.dev == self.identity.dev and st.ino == self.identity.ino then
				uv.fs_unlink(path)
			end
		end
	end

	local bound, bind_err = checked(listener.bind, listener, path)
	if not bound then
		self:stop()
		return nil, "cannot bind socket: " .. bind_err
	end
	if not windows then
		self.identity = uv.fs_lstat(path)
		if not self.identity or self.identity.type ~= "socket" then
			self:stop()
			return nil, "cannot identify bound socket"
		end
		if limits.gid then
			local changed, chown_err = checked(uv.fs_chown, path, -1, limits.gid)
			if not changed then
				self:stop()
				return nil, "cannot set socket group: " .. chown_err
			end
		end
		local changed, chmod_err = checked(uv.fs_chmod, path, limits.mode)
		if not changed then
			self:stop()
			return nil, "cannot set socket mode: " .. chmod_err
		end
	end

	local function reply(client, value)
		if client.closed or client.responding then
			return
		end
		client.responding = true
		client.pipe:read_stop()
		client.buffer = nil
		local data = vim.json.encode(value) .. "\n"
		local written = checked(client.pipe.write, client.pipe, data, function()
			close_client(client)
		end)
		if not written then
			close_client(client)
		end
	end

	local listening, listen_err = checked(listener.listen, listener, 128, function(accept_err)
		if accept_err or self.closed then
			return
		end
		local pipe = uv.new_pipe(false)
		local accepted = checked(listener.accept, listener, pipe)
		if not accepted or self.count >= limits.max_clients then
			close_handle(pipe)
			return
		end
		local client = { pipe = pipe, buffer = "", closed = false, responding = false, processing = false }
		self.clients[client] = true
		self.count = self.count + 1
		client.timer = uv.new_timer()
		client.timer:start(limits.request_timeout_ms, 0, function()
			-- A peer that does not read its response must not hold a slot forever.
			if client.responding then
				close_client(client)
				return
			end
			reply(client, protocol.error("timeout", "request deadline exceeded"))
			if not client.closed then
				client.timer:start(100, 0, function()
					close_client(client)
				end)
			end
		end)
		local reading = checked(pipe.read_start, pipe, function(read_err, data)
			if client.closed or client.processing or client.responding then
				return
			end
			if read_err or not data then
				close_client(client)
				return
			end
			local newline = data:find("\n", 1, true)
			local length = #client.buffer + (newline and newline - 1 or #data)
			if length > limits.max_message_bytes then
				reply(client, protocol.error("message_too_large", "request exceeds the byte limit"))
				return
			end
			if not newline then
				client.buffer = client.buffer .. data
				return
			end
			if newline ~= #data then
				reply(client, protocol.error("invalid_request", "send one JSON request per connection"))
				return
			end
			local frame = client.buffer .. data:sub(1, newline - 1)
			client.buffer = nil
			client.processing = true
			pipe:read_stop()
			-- Admission touches Neovim state, so it must not run in a fast event.
			vim.schedule(function()
				if self.closed or client.closed or client.responding then
					return
				end
				local ok, result = pcall(protocol.handle, frame)
				if not ok then
					result = protocol.error("internal_error", "request could not be processed")
				end
				reply(client, result)
			end)
		end)
		if not reading then
			close_client(client)
		end
	end)
	if not listening then
		self:stop()
		return nil, "cannot listen on socket: " .. listen_err
	end
	return self
end

return M
