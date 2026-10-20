---
name: codeforge-review
description: Install, configure, and operate the CodeForge Neovim plugin, which is the receiving half of a human-in-the-loop review workflow. Use when a change set published by an agent is waiting in the sidebar, when triaging or resolving its hunks, when a published change looks wrong or will not complete, or when setting up CodeForge in a Neovim config. Do not use for publishing from the CLI side; an agent-facing skill covers that.
---

# Review incoming changes in CodeForge

CodeForge turns an agent's proposed edit into a reviewable change set inside
Neovim. The agent publishes a revision range; the plugin diffs it into hunks,
applies the proposal in the real file buffer, and records your decisions per
hunk. The agent reads those decisions back afterwards. Committing and merging
stay outside CodeForge. What it produces is a triaged buffer that you save like
any other edit.

Reviewing is a loop. Open the change, walk its hunks, accept or reject each one,
resolve any where the proposal and your own edits disagree, then let the change
close out.

## Install

The hard requirements are `git` on `PATH` (accepting a hunk shells out to
`git merge-file`), and [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui)
with its own dependencies (`nvim-dap`, `nvim-nio`), because the sidebar is a
dap-ui element. Both dependencies must be on `runtimepath` before CodeForge
initializes.

With `lazy.nvim`:

```lua
{
  dir = "/path/to/codeforge-nvim",
  dependencies = {
    "rcarriga/nvim-dap-ui",
    "mfussenegger/nvim-dap",
    "nvim-neotest/nvim-nio",
  },
  opts = {},
}
```

Or add the checkout to `runtimepath` directly:

```lua
vim.opt.runtimepath:append("/path/to/codeforge-nvim")
```

Setup is optional. At `VimEnter` the plugin initializes itself, taking options
from `vim.g.codeforge_setup` (a table) or from a `setup()` call that already
ran. Set `vim.g.codeforge_setup = false` to opt out entirely.

```lua
require("codeforge").setup({
  -- `true` (the default) persists reviews to
  -- stdpath('data')/codeforge/session.json, `false` disables persistence,
  -- and a string names the file to use
  session = true,

  -- `true` or nil listens on stdpath("run")/codeforge.sock, a string sets the
  -- path, false disables the socket, a table carries full socket options
  socket = true,
})
```

Socket options are `path`, `group`, `mode` (a three-digit octal string), and the
limits `max_message_bytes`, `max_clients`, `request_timeout_ms`. Group and mode
cannot be enforced on Windows named pipes.

`keymaps` needs care. Setup force-merges your options into the config, so a
`keymaps` table you pass replaces the whole default table rather than extending
it. Remapping one key that way silently drops every other binding, which does
happen with most plugin managers' `opts`. Extend the defaults explicitly
instead:

```lua
local codeforge = require("codeforge")
codeforge.setup({
  keymaps = vim.tbl_extend("force", codeforge.config.keymaps, {
    accept_hunk = "<leader>ca",
  }),
})
```

Setting a single key to `false` in that merged table drops just that binding,
since every mapping helper skips a falsey key. The same applies to a `keymaps`
table placed in `vim.g.codeforge_setup`.

The default socket is `stdpath("run")/codeforge.sock`, which is per-user. When
an agent runs as a different account, point both sides at a shared path and
widen access there:

```lua
require("codeforge").setup({
  socket = { path = "/tmp/codeforge.sock", group = "codeforge", mode = "660" },
})
```

Verify the whole setup with `:checkhealth codeforge`. It is read-only, and it
reports the `git` binary, whether `dapui` resolves, whether setup ran, the
socket state, and writability of the decision-log and session paths.

## Open the review

`:CodeForge` toggles the sidebar. It opens on the right at 40 columns. A
published change is tracked the moment the agent sends it, before any review is
opened, so it can appear while you are working.

The sidebar lists the current change with its derived status, its files, and
their hunks, then a `Completed` section for changes finished this session.
Header glyphs are `○` for pending, `●` for accepted or rejected, and `◐` for
modified. Per-file rows use the same glyphs, and show `⚠` when a file failed.

Sidebar keys, all buffer-local:

| key | action |
|---|---|
| `<C-]>` / `<C-[>` | next / previous change |
| `o` | expand a file, preview an added file, decide a deleted file, reopen a completed change |
| `<CR>` | open the review for a file, or jump to the hunk under the cursor |
| `<C-x>A` / `<C-x>J` | accept / reject every pending part of the change |
| `<C-x>u` / `<C-x>R` | undo / redo the last triage action |

`o` on an `added` file previews it without deciding anything. On a `modified`
file it only expands the hunk list. On a `deleted` file it toggles the
whole-file decision.

## Triage hunks in the real buffer

`<CR>` on a file opens it in your main window with the proposal already applied.
The diff is rendered in place rather than in a separate split, so surrounding
code, LSP, and your usual editing all keep working.

| key | action |
|---|---|
| `<C-x>a` | accept the hunk at the cursor |
| `<C-x>j` | reject the hunk at the cursor |
| `<C-x>c` | resolve a conflicted hunk |
| `<C-x>n` / `<C-x>b` | next / previous hunk |
| `<C-x>d` | dismiss the review for this file |
| `<C-x>t` / `<C-x>r` | expand a deletion fold / restore the deleted lines |
| `<C-x>p` | toggle a diff popup for the hunk at the cursor |
| `<C-x>u` / `<C-x>R` | undo / redo the last triage action |

The buffer is the proposal, annotated with extmarks and virtual lines. Added
lines carry `+`, modified lines carry `~`, and a folded deletion reads
`- N lines removed`. None of that annotation is a change to the buffer's text,
so the content reaches disk when you save, as with any other edit.

Accepting is a three-way merge between your pre-review content, the agent's
base, and the proposal. That is what lets an accept keep the edits you already
had instead of clobbering them. When those three disagree inside a hunk's
region, the hunk becomes `conflicted` rather than the plugin silently picking a
side.

The sweep keys (`<C-x>A`, `<C-x>J`) act change-wide. They decide added and
deleted files as a whole and every pending hunk of every modified file, opening
review records as needed. Both sweep a whole change into one undo step. A sweep
leaves already-conflicted hunks alone and then warns how many remain, and the
accept sweep can mark a hunk conflicted itself instead of accepting it.

### Resolving a conflicted hunk

`<C-x>c` on a conflicted hunk opens a merge view for that region only. Inside
it `<C-x>o` takes your side, `<C-x>p` takes the proposal, and `<C-x>f` confirms
the whole buffer as it stands, so edit it freely first. The result is marked
`accepted`.

Resolution is limited to the hunk's region. If edits you made before or during
the review overlap in a way that cannot be assembled, completion is refused with
a message telling you to reconcile or discard one side. Fix that before
dismissing or closing out.

## What each outcome means

A change's status is derived from its parts. Any pending part keeps the whole
change `pending`. Otherwise:

- `accepted`: everything was accepted.
- `rejected`: everything was rejected.
- `modified`: mixed accept/reject, a hand-edit away from the proposal, or a file
  that failed to write.

`modified` is the informative outcome. It tells the agent that its assumption
was wrong. Editing the proposal in place is meaningful for exactly that reason.
An edit that diverges from what the agent sent is what makes a change report
`modified` even when you accepted every hunk.

An all-rejected change reports `rejected` rather than a failure, so rejection is
a clean signal the agent can act on, not a soft error.

## Disk and save behaviour

A review buffer is `acwrite` with a save guard.

- Saving during a review works while the on-disk file has not changed since the
  review opened or since your last save.
- If something else changed the file on disk, saving errors and tells you to
  `:e` and inspect. The guard exists so a review cannot overwrite work another
  process wrote.
- Dismissing a review assembles the final content back into the buffer and
  drops the review record. It refuses while a conflicting gap remains.

Added files are the exception. Accepting one writes it to disk immediately,
creating missing parent directories. Nothing is overwritten. If anything already
occupies the target path, including a dangling symlink, the write is refused and
the file is marked failed, which turns the change `modified`. Rejecting an added
file removes a file that review created and prunes directories it made, stopping
at the first non-empty directory.

Deleting a file is atomic too. A whole-file decision settles it, and the buffer
content follows that decision rather than a per-hunk merge.

## Close out and revisit

A change completes as soon as no part is pending. It moves to `Completed` with
its outcome, any open reviews are dismissed, and a decision is appended to the
log. That log is what makes outcomes durable. An agent can still ask for a
change's result after Neovim restarted, and a reopened change leaves the
outcome it followed intact in the log.

Undo is scoped to triage actions within the session. It can also revive a
change that the very action you are undoing had just completed, which is the way
to take back an accidental sweep. Withdrawing a change from the agent's history
is outside its reach, because the log already has an entry by then.

`o` on a row in `Completed` reopens it as a fresh review round, clearing the
decisions and using the previous final content as the new baseline.

## When a change looks wrong

Publishing is create-only. There is no retract, and a proposal is refused when
any of its paths is already tracked by another pending change. A published
change therefore stays in the queue until you triage it. If an agent sends
something wrong, reject it and say so, rather than letting two proposals for
the same file accumulate.

## Diagnose a problem

`:checkhealth codeforge` first, then match the symptom:

- **No sidebar, or `:CodeForge` errors on `dapui`**: the dependency is not on
  `runtimepath` before CodeForge initializes.
- **An agent cannot connect**: the socket path it uses differs from the one
  listening, usually because it runs as another account. Access is filesystem
  permissions rather than authentication, and the socket accepts a fixed set of
  data operations without executing editor code.
- **A publish is refused**: the reply names every refused path with a reason.
  A `modified` target must exist as a regular file on the receiving editor's
  disk, and relative paths resolve against the editor's working directory.
- **The change stays pending**: some part is still untriaged, including hunks in
  files you have not opened. Expand the change in the sidebar to find them, or
  use a sweep key and then resolve what the warning reports.

Where state lives, both under `stdpath("data")/codeforge/`:

- `session.json` holds in-progress change sets and triage, restored silently on
  restart. `session = false` disables it.
- `log.json` is the append-only decision log, one entry per completed change.
