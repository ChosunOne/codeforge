local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()

---Restart the child with the real runtimepath but WITHOUT the harness calling
---setup(), so plugin/codeforge.lua is the only thing that can initialize us.
---Auto-setup is pointed at disposable socket/session settings so a test can
---never clobber the developer's real review state. Extra --cmd args run before
---init.lua, i.e. before plugin sourcing.
---@param pre? string  a Vimscript fragment passed as a single --cmd
local function restart_unsetup(pre)
	vim.env.CODEFORGE_TEST_NO_SETUP = "1"
	vim.env.CODEFORGE_TEST_SESSION = "/dev/null" -- never write a real session
	local args = { "-u", "tests/init.lua" }
	if pre then
		args[#args + 1] = "--cmd"
		args[#args + 1] = pre
	end
	child.restart(args)
	vim.env.CODEFORGE_TEST_NO_SETUP = nil
	vim.env.CODEFORGE_TEST_SESSION = nil
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			-- Disable side effects by default; individual cases override.
			restart_unsetup([[let g:codeforge_setup = {'socket': v:false, 'session': v:false}]])
		end,
		post_case = function()
			vim.env.CODEFORGE_TEST_NO_SETUP = nil
			vim.env.CODEFORGE_TEST_SESSION = nil
		end,
		post_once = child.stop,
	},
})

T["the plugin auto-initializes when the user never calls setup()"] = function()
	MiniTest.expect.equality(child.lua_get([[require("codeforge")._initialized]]), true)
	MiniTest.expect.equality(child.lua_get([[vim.fn.exists(":CodeForge")]]), 2, {
		fail_reason = "the :CodeForge command must exist without a manual setup()",
	})
end

T["auto-initialization happens exactly once and setup() is idempotent"] = function()
	MiniTest.expect.equality(child.lua_get([[require("codeforge")._initialized]]), true)
	child.lua([[require("codeforge").setup()]])
	local config = child.lua_get([[require("codeforge").config]])
	MiniTest.expect.equality(type(config), "table")
end

T["vim.g.codeforge_setup = false opts out of auto-initialization entirely"] = function()
	restart_unsetup("let g:codeforge_setup = v:false")
	MiniTest.expect.equality(child.lua_get([[require("codeforge")._initialized]]), false, {
		fail_reason = "false must suppress auto-setup",
	})
	MiniTest.expect.equality(child.lua_get([[vim.fn.exists(":CodeForge")]]), 0, {
		fail_reason = "opting out must not create the :CodeForge command",
	})
	-- ...but a manual setup() must still work after opting out.
	child.lua([[require("codeforge").setup({ socket = false, session = false })]])
	MiniTest.expect.equality(child.lua_get([[vim.fn.exists(":CodeForge")]]), 2)
end

T["vim.g.codeforge_setup as a table is passed through to setup()"] = function()
	restart_unsetup(
		[[let g:codeforge_setup = {'socket': v:false, 'session': v:false, 'keymaps': {'accept_hunk': '<leader>x'}}]]
	)
	MiniTest.expect.equality(child.lua_get([[require("codeforge")._initialized]]), true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge").config.keymaps.accept_hunk]]), "<leader>x")
	MiniTest.expect.equality(child.lua_get([[require("codeforge").config.socket]]), false)
end

T["a plugin sourced after VimEnter still auto-initializes"] = function()
	-- Lazy-loaded plugin dirs are sourced after VimEnter, so a VimEnter
	-- autocmd would never fire. Sourcing must initialize immediately instead.
	local root = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h"), ":h")
	child.restart({}) -- clean child: our repo is NOT on the rtp at startup
	-- Prove we start uninitialized and past VimEnter.
	MiniTest.expect.equality(child.lua_get([[vim.v.vim_did_enter]]), 1)
	-- Provide the runtime dependencies setup() needs, then source the plugin
	-- the way a lazy loader would, after startup.
	child.lua(
		string.format([[vim.opt.runtimepath:append(%s)]], vim.inspect(vim.fn.stdpath("data") .. "/lazy/nvim-dap-ui"))
	)
	child.lua(
		string.format([[vim.opt.runtimepath:append(%s)]], vim.inspect(vim.fn.stdpath("data") .. "/lazy/nvim-dap"))
	)
	child.lua(
		string.format([[vim.opt.runtimepath:append(%s)]], vim.inspect(vim.fn.stdpath("data") .. "/lazy/nvim-nio"))
	)
	child.lua(string.format([[vim.opt.runtimepath:append(%s)]], vim.inspect(root)))
	child.lua([[vim.g.loaded_codeforge = nil]])
	child.lua([[vim.g.codeforge_setup = { socket = false, session = false }]])
	child.lua([[vim.cmd("runtime plugin/codeforge.lua")]])
	MiniTest.expect.equality(child.lua_get([[require("codeforge")._initialized]]), true, {
		fail_reason = "sourcing the plugin after VimEnter must initialize immediately",
	})
end

T["an explicit user setup() wins over auto-initialization"] = function()
	-- Normal harness path: tests/init.lua calls setup({socket=false,...}) BEFORE
	-- plugin/codeforge.lua is sourced. Auto-setup must not clobber it.
	child.restart({ "-u", "tests/init.lua" })
	MiniTest.expect.equality(child.lua_get([[require("codeforge")._initialized]]), true)
	MiniTest.expect.equality(child.lua_get([[require("codeforge").config.socket]]), false, {
		fail_reason = "auto-setup must not overwrite the user's explicit configuration",
	})
	MiniTest.expect.equality(child.lua_get([[require("codeforge").config.session]]), false)
end

return T
