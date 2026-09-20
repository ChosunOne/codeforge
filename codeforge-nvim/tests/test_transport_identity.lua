do
	local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	package.path = dir .. "/?.lua;" .. package.path
end

local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local F = require("fixtures")
F.set_child(child)
local project_dir, original_cwd

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "-u", "tests/init.lua" })
			original_cwd = child.fn.getcwd()
			project_dir = F.tmp_path("_project")
			child.fn.mkdir(project_dir, "p")
			child.api.nvim_set_current_dir(project_dir)
			child.fn.writefile({ "a", "b" }, "identity-a.lua")
			child.lua([[
				require("codeforge.state").reset()
				_G.proposal = {
					files = {
						{ path = "identity-a.lua", status = "modified", base = { "a", "b" }, hunks = {
							{ old_start = 2, old_lines = 1, new_start = 2, new_lines = 1, lines = { "-b", "+B" } },
							{ old_start = 1, old_lines = 1, new_start = 1, new_lines = 1, lines = { "-a", "+A" } },
						} },
						{ path = "identity-b.lua", status = "added", hunks = {
							{ old_start = 1, old_lines = 0, new_start = 1, new_lines = 1, lines = { "+new" } },
						} },
					},
				}
			]])
		end,
		post_case = function()
			child.api.nvim_set_current_dir(original_cwd)
			child.fn.delete(project_dir, "rf")
			F.cleanup()
		end,
		post_once = child.stop,
	},
})

T["admission owns identity and returns a detached receipt in request order"] = function()
	child.lua([[
		local before = vim.deepcopy(proposal)
		local transport = require("codeforge.transport")
		assert(transport.validate(proposal) == nil)
		local ok, ack = transport.receive(proposal)
		assert(ok, vim.inspect(ack))
		assert(vim.deep_equal(before, proposal), "admission mutated the caller's proposal")
		assert(type(ack) == "table" and type(ack.id) == "string" and #ack.id > 0)
		local change = require("codeforge.state").changes[1]
		assert(ack.id == change.id and change.title == ack.id)
		assert(#ack.files == 2)
		local seen = { [ack.id] = true }
		for i, file in ipairs(change.files) do
			assert(ack.files[i].path == file.path)
			assert(#ack.files[i].hunks == #file.hunks)
			for j, hunk in ipairs(file.hunks) do
				assert(type(hunk.id) == "string" and #hunk.id > 0 and not seen[hunk.id])
				seen[hunk.id] = true
				assert(ack.files[i].hunks[j].id == hunk.id, "receipt must use request order, not sorted base order")
				assert(hunk.old_start == proposal.files[i].hunks[j].old_start)
			end
		end
		local saved = vim.deepcopy(change)
		ack.id = "tampered"
		ack.files[1].path = "tampered.lua"
		ack.files[1].hunks[1].id = "tampered"
		proposal.files[1].hunks[1].lines[2] = "+tampered"
		assert(vim.deep_equal(saved, change), "receipt/input aliases leaked into state")
	]])
end

for _, location in ipairs({ "proposal", "proposal.files[2]", "proposal.files[2].hunks[1]" }) do
	T["caller ids are rejected at " .. location .. " even when false or null"] = function()
		child.lua(string.format(
			[[
			for _, id in ipairs({ "chosen", "", false, 42, {}, vim.NIL }) do
				%s.id = id
				local ok, err = require("codeforge.transport").receive_json(vim.json.encode(proposal))
				assert(not ok and err:find("id is assigned by Neovim", 1, true), vim.inspect(err))
				assert(#require("codeforge.state").changes == 0)
			end
		]],
			location
		))
	end
end

T["publish cannot overwrite an existing change by echoing its assigned id"] = function()
	child.lua([[
		local transport, state = require("codeforge.transport"), require("codeforge.state")
		local ok, ack = transport.receive(proposal)
		assert(ok, vim.inspect(ack))
		local before = vim.deepcopy(state.changes)
		proposal.id = ack.id
		proposal.title = "replacement"
		ok, ack = transport.receive(proposal)
		assert(not ok and ack:find("id is assigned by Neovim", 1, true))
		assert(vim.deep_equal(before, state.changes))
		proposal.id = nil
		ok, ack = transport.receive(proposal)
		assert(not ok and ack:find("already tracked", 1, true), "id-less retry must not replace either")
		assert(vim.deep_equal(before, state.changes))
	]])
end

T["identities remain distinct across completion, state reset and rapid publishing"] = function()
	child.lua([[
		local transport, state = require("codeforge.transport"), require("codeforge.state")
		local seen = {}
		for i = 1, 20 do
			local ok, ack = transport.receive(proposal)
			assert(ok, vim.inspect(ack))
			assert(not seen[ack.id], "change identity was reused")
			seen[ack.id] = true
			for _, file in ipairs(ack.files) do
				for _, hunk in ipairs(file.hunks) do
					assert(not seen[hunk.id], "hunk identity was reused")
					seen[hunk.id] = true
				end
			end
			if i % 2 == 0 then
				state.reset()
			else
				-- Completed objects and log entries reserve their old identities.
				state.completed[ack.id] = { change = state.changes[1] }
				state.log[#state.log + 1] = { id = ack.id, status = "accepted" }
				state.changes = {}
				state.current_change_id, state.current_change_index = nil, nil
			end
		end
	]])
end

for _, retained in ipairs({ "pending", "completed", "log" }) do
	T["identity allocation avoids " .. retained .. " ids after module reload"] = function()
		child.lua(string.format(
			[[
			-- Force the same random prefix: collision avoidance must not depend
			-- solely on the random source never repeating.
			vim.uv.random = function() return string.rep("x", 16) end
			local state = require("codeforge.state")
			local ok, first = require("codeforge.transport").receive(proposal)
			assert(ok, vim.inspect(first))
			local retained = %q
			if retained ~= "pending" then
				local change = table.remove(state.changes)
				state.current_change_id, state.current_change_index = nil, nil
				if retained == "completed" then
					state.completed[first.id] = { change = change }
				else
					state.log = { { id = first.id, status = "accepted" } }
				end
			end
			for _, file in ipairs(proposal.files) do file.path = "next-" .. file.path end
			vim.fn.writefile(proposal.files[1].base, proposal.files[1].path)
			package.loaded["codeforge.transport"] = nil
			local second
			ok, second = require("codeforge.transport").receive(proposal)
			assert(ok, vim.inspect(second))
			assert(first.id ~= second.id, "retained change identity was reused")
			assert(first.files[1].hunks[1].id ~= second.files[1].hunks[1].id)
		]],
			retained
		))
	end
end

T["path admission checks precede identity allocation"] = function()
	child.lua([[
		vim.uv.random = function() error("identity allocated before admission checks") end
		local transport, state = require("codeforge.transport"), require("codeforge.state")
		local original = vim.deepcopy(proposal)
		proposal.files[2] = vim.deepcopy(proposal.files[1])
		proposal.files[2].path = "./" .. proposal.files[1].path
		local ok, err = transport.receive(proposal)
		assert(not ok and err:find("duplicate file path", 1, true), vim.inspect(err))
		assert(#state.changes == 0)
		state.changes = { { id = "existing", files = { { path = original.files[1].path } } } }
		ok, err = transport.receive(original)
		assert(not ok and err:find("already tracked", 1, true), vim.inspect(err))
		assert(#state.changes == 1 and state.changes[1].id == "existing")
	]])
end

T["invalid input never reaches identity allocation"] = function()
	child.lua([[
		vim.uv.random = function() error("identity allocated before validation") end
		proposal.files[2].hunks[1].new_lines = 999
		local ok, err = require("codeforge.transport").receive(proposal)
		assert(not ok and err:find("new_lines", 1, true), vim.inspect(err))
		assert(#require("codeforge.state").changes == 0)
	]])
end

T["identity allocation failure leaves admission untouched"] = function()
	child.lua([[
		vim.uv.random = function() return nil, "entropy unavailable" end
		local state = require("codeforge.state")
		state.set_on_change(function() error("must not refresh on failed allocation") end)
		local ok, err = require("codeforge.transport").receive(proposal)
		assert(not ok and err:find("identity", 1, true), vim.inspect(err))
		assert(#state.changes == 0 and state.current_change_id == nil)
	]])
end

return T
