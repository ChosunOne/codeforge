# CodeForge

An AI code-review workflow. An agent publishes a change set to a running
Neovim instance over a Unix socket; the user reviews it hunk by hunk in a
sidebar and in the real file buffer, and the agent reads the outcome back.

Two components live in this repository.

- `codeforge-nvim/` is the Neovim plugin. It owns all review state and hosts
  the socket.
- `codeforge-agent/` is the `codeforge` CLI. It builds proposals from a `jj`
  revision range and talks to the socket.

## Requirements

- Neovim 0.11 or newer
- `git` on `PATH`
- `jj` on `PATH` (used by the CLI to read revisions)
- Rust 1.85 or newer (edition 2024) to build the CLI
- [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui) and its dependencies
  (`nvim-dap`, `nvim-nio`) for the sidebar

## Install

### Neovim plugin

Add the plugin with any plugin manager. With `lazy.nvim`:

```lua
{
  dir = "/path/to/codeforge/codeforge-nvim",
  dependencies = {
    "rcarriga/nvim-dap-ui",
    "mfussenegger/nvim-dap",
    "nvim-neotest/nvim-nio",
  },
  opts = {},
}
```

The plugin also works with a plain `runtimepath` entry. On startup it
auto-initializes unless `vim.g.codeforge_setup = false`.

```lua
vim.opt.runtimepath:append("/path/to/codeforge/codeforge-nvim")
```

Dependencies must be on `runtimepath` before CodeForge initializes.

### Agent CLI

```sh
cd codeforge-agent
cargo build --release
install -Dm755 target/release/codeforge ~/.local/bin/codeforge
```

Or install straight from the directory:

```sh
cargo install --path codeforge-agent
```

## Configure

### Neovim

`require("codeforge").setup()` is optional; pass options to it or set
`vim.g.codeforge_setup` to a table before the plugin loads.

```lua
require("codeforge").setup({
  -- true (default) persists reviews under stdpath("data")/codeforge/session.json,
  -- false disables persistence, or give an explicit file path
  session = true,

  -- true or nil listens on stdpath("run")/codeforge.sock,
  -- a string sets the path, false disables the socket,
  -- a table is passed through as socket options ({ path = "..." })
  socket = true,

  -- override any of the default review keymaps
  keymaps = {
    -- next_change = "<C-]>",
    -- prev_change = "<C-[>",
    -- accept_hunk = "<C-x>a",
    -- reject_hunk = "<C-x>j",
    -- resolve_hunk = "<C-x>c",
    -- accept_pending = "<C-x>A",
    -- reject_pending = "<C-x>J",
    -- undo = "<C-x>u",
    -- redo = "<C-x>R",
    -- dismiss = "<C-x>d",
  },
})
```

Open the sidebar with `:CodeForge`. Review keymaps are buffer-local and become
active in the sidebar and review buffers.

### Socket address

The editor listens on `stdpath("run")/codeforge.sock` by default, which is
normally `/run/user/<uid>/codeforge.sock`. The CLI resolves the address in this
order:

1. `--socket PATH`
2. `CODEFORGE_SOCKET`
3. `$XDG_RUNTIME_DIR/codeforge.sock`, falling back to
   `/run/user/<uid>/codeforge.sock`

When the agent runs as a different user than the editor, set `CODEFORGE_SOCKET`
or pass `--socket` explicitly, and make the socket readable by both accounts.
Check the live address with:

```sh
codeforge info
```

## Use

Publish a `jj` revision range:

```sh
codeforge publish --repo /path/to/project --from @- --to @ --title "Add validation"
```

The command prints the assigned change id. Wait for the review to finish:

```sh
codeforge status --id <id> --wait --timeout 600
```

Exit codes are `0` success, `1` failure, `2` usage error, `3` still awaiting
review. List known changes with `codeforge list`.

## Troubleshooting

```vim
:checkhealth codeforge
```

The health check reports `git`, `dapui`, initialization, socket state, and the
decision-log and session paths.
