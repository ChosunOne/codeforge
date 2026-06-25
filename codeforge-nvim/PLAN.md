# AI Review Workflow - Implementation Plan

## Architecture Overview

```
┌─────────────────┐         ┌──────────────────┐
│  AI Agent       │         │  User (Neovim)   │
│  (separate user)│         │  (main user)     │
└────────┬────────┘         └────────┬─────────┘
         │                           │
         │ Socket/Named Pipe         │
         │ (Unix/Windows)            │
         │                           │
┌────────▼───────────────────────────▼─────────┐
│              Agent Harness Plugin              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Transport│  │  Store   │  │  Tools   │   │
│  │ (Socket) │  │ (SQLite) │  │ (MCP)    │   │
│  └──────────┘  └──────────┘  └──────────┘   │
└───────────────────────────────────────────────┘
         ▲                           │
         │ Message Protocol          │ File Write
         │ (JSON)                    │ (direct)
         │                           ▼
┌────────┴──────────────────────────────────────┐
│              Neovim Plugin                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Client  │  │ Sidebar  │  │  Review  │   │
│  │ (Socket) │  │(dap-ui)  │  │(gitsigns)│   │
│  └──────────┘  └──────────┘  └──────────┘   │
└───────────────────────────────────────────────┘
```

## Message Protocol

### Core Message Types

```typescript
type Message =
  | { type: 'publish'; id: string; changes: ChangeSet }
  | { type: 'modify'; id: string; changes: ChangeSet }
  | { type: 'view'; id: string }
  | { type: 'retract'; id: string }
  | { type: 'accept'; id: string; file: string; hunks: HunkId[]; content?: string }
  | { type: 'reject'; id: string; file: string; hunks: HunkId[] }
  | { type: 'sync_request'; id: string; file: string }
  | { type: 'sync_response'; id: string; content: string }
  | { type: 'notification'; level: 'info'|'error'|'success'; message: string }
  | { type: 'state_change'; id: string; state: ReviewState }

interface ChangeSet {
  id: string;
  files: FileChange[];
  timestamp: number;
  metadata?: Record<string, unknown>;
}

interface FileChange {
  path: string;
  hunks: Hunk[];
  status: 'added' | 'modified' | 'deleted' | 'renamed';
}

interface Hunk {
  id: string;
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  lines: string[];  // jj diff format
  header: string;
}
```

## SQLite Schema

```sql
-- Changes table
CREATE TABLE changes (
    id TEXT PRIMARY KEY,
    status TEXT CHECK(status IN ('pending', 'reviewing', 'accepted', 'rejected', 'partial')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    metadata TEXT -- JSON
);

-- Files table
CREATE TABLE files (
    id TEXT PRIMARY KEY,
    change_id TEXT NOT NULL REFERENCES changes(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    status TEXT CHECK(status IN ('added', 'modified', 'deleted', 'renamed')),
    content TEXT, -- Full file content for sync
    UNIQUE(change_id, path)
);

-- Hunks table
CREATE TABLE hunks (
    id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    old_start INTEGER,
    old_lines INTEGER,
    new_start INTEGER,
    new_lines INTEGER,
    lines TEXT NOT NULL, -- JSON array of diff lines
    header TEXT,
    status TEXT CHECK(status IN ('pending', 'accepted', 'rejected')),
    modified_content TEXT -- If user edited the hunk
);

-- Review state (for recovery)
CREATE TABLE review_state (
    change_id TEXT NOT NULL REFERENCES changes(id) ON DELETE CASCADE,
    file_path TEXT NOT NULL,
    cursor_line INTEGER,
    cursor_col INTEGER,
    sidebar_state TEXT, -- JSON
    PRIMARY KEY (change_id, file_path)
);
```

## Socket Strategy

### Platform-Specific Defaults

```typescript
// Linux
const linuxSocket = `/run/user/${process.getuid()}/ai-review.sock`;

// macOS
const macSocket = `${os.homedir()}/Library/Application Support/ai-review/ai-review.sock`;

// Windows (Named Pipe)
const windowsPipe = `\\.\pipe\ai-review`;

// Configurable via environment variable
const socketPath = process.env.AI_REVIEW_SOCKET || getDefaultSocketPath();

// Permissions (Linux/macOS only)
// chmod 660 with configurable group
// Group set via AI_REVIEW_GROUP env var
```

## Implementation Phases

### Phase 1: Foundation + Testing Infrastructure

**Agent Harness Plugin:**
- [ ] Socket transport layer (cross-platform)
- [ ] Message protocol (JSON serialization/deserialization)
- [ ] SQLite schema with migrations
- [ ] MCP tools:
  - `publish_changes`: Create new change set
  - `view_change`: Get change details
  - `retract_change`: Remove pending change
  - `modify_change`: Update existing change
- [ ] **Testing:**
  - Socket transport unit tests (mock server/client)
  - Protocol message tests (roundtrip serialization)
  - SQLite store tests (CRUD operations, migrations)
  - MCP tool integration tests

**Neovim Plugin:**
- [ ] Socket client with reconnection logic
- [ ] Message protocol implementation
- [ ] Configuration system
- [ ] **Testing:**
  - Socket client tests with mock server
  - Protocol message tests
  - Configuration tests

**Testing Strategy Phase 1:**
- Agent harness: Use Node.js test runner (built-in) or Vitest
- Neovim: Use mini.test with child process isolation
- Create test fixtures for sample jj diffs

### Phase 2: Core Review Flow + UI Testing

**Agent Harness Plugin:**
- [ ] Change application logic (write to user files)
- [ ] Sync response handling
- [ ] Notification system
- [ ] **Testing:**
  - End-to-end flow tests (publish → apply → notify)
  - Sync recovery tests

**Neovim Plugin:**
- [ ] Sidebar integration (nvim-dap-ui):
  - Collapsible file tree
  - Hunk expansion on hover
  - Status indicators
- [ ] Hunk display (gitsigns):
  - Show hunks inline
  - Navigation between hunks
  - Sign column indicators
- [ ] Review actions:
  - Accept file (write all hunks)
  - Reject hunk (revert single hunk)
  - Accept hunk (write single hunk)
- [ ] LSP integration for review buffers
- [ ] **Testing:**
  - UI tests with mini.test screenshots
  - Sidebar interaction tests
  - Hunk display verification
  - Action handler tests
  - Visual verification tests (openable in real Neovim)

**Testing Strategy Phase 2:**
- mini.test for precise UI assertions
- Screenshot reference files for visual verification
- Test data openable in actual Neovim instance
- No file creation in tests (use buffers/fixtures)

### Phase 3: Sync & State + Recovery Testing

**Agent Harness Plugin:**
- [ ] Bidirectional sync (receive user modifications)
- [ ] Hunk-level vs full file sync
- [ ] Conflict detection and queueing
- [ ] State persistence for crash recovery
- [ ] **Testing:**
  - Sync protocol tests
  - Conflict resolution tests
  - Crash recovery tests
  - Concurrent access tests

**Neovim Plugin:**
- [ ] State persistence (SQLite via agent harness):
  - Cursor position
  - Sidebar state
  - Review progress
- [ ] Queue management for conflicting changes
- [ ] Automatic recovery on restart
- [ ] **Testing:**
  - State persistence tests
  - Recovery scenario tests
  - Queue behavior tests

### Phase 4: Polish + E2E Testing

**Both Plugins:**
- [ ] TCP fallback for socket failures
- [ ] Configuration validation
- [ ] Error handling and user feedback
- [ ] Documentation

**Testing Strategy Phase 4:**
- [ ] E2E tests with both plugins running
- [ ] Manual verification tests
- [ ] Edge case tests

## Project Structure

The Neovim plugin is the only part implemented so far. The agent-harness
plugin is planned (see Implementation Phases) but does not exist in this repo;
it will live in a separate repository.

### Current (implemented)

```
codeforge-nvim/
├── lua/codeforge/
│   ├── init.lua                  # setup(); dap-ui element + :CodeForge command
│   ├── state.lua                 # in-memory review state (changes/files/hunks)
│   └── sidebar/
│       └── element.lua           # dap-ui element: renders tree, keymaps
├── plugin/
│   └── codeforge.lua             # (empty; no autoloaded entry yet)
├── tests/
│   ├── init.lua                  # minimal init: rtp + mini.test + codeforge.setup
│   ├── test_setup.lua            # sanity that setup loads
│   ├── test_sidebar.lua          # opens on right, shows title, no-changes
│   ├── test_sidebar_changes.lua  # header count, next/prev change w/ wraparound
│   ├── test_sidebar_files_hunks.lua  # file listing; expand file -> hunks
│   └── screenshots/              # mini.test reference screenshots
├── .luarc.json
└── PLAN.md                       # this file
```

### Planned additions to the Neovim plugin (see "Edit Buffer / Review Flow" below)

```
lua/codeforge/review/
│   ├── buffer.lua   # open/swap/dismiss; snapshot U; load P; assemble final
│   ├── diff.lua     # virtual-fold extmarks (deletions), add-line hl, per-hunk marks
│   ├── apply.lua    # per-hunk accept/reject; git merge-file 3-way; conflict detect
│   ├── resolve.lua  # 3-way :diffthis sub-flow, diffget handlers, finalize region
│   └── actions.lua  # keymap handlers, find/open real buffer, wire review <-> sidebar
```

Transport (`lua/codeforge/transport/`), protocol, and persistence will be added
when the agent-harness integration begins; their layout is not yet fixed.

### Planned: agent-harness plugin (separate repo)

```
agent-harness-plugin/
├── src/
│   ├── index.ts              # Entry point
│   ├── transport/
│   │   ├── server.ts         # Socket server
│   │   ├── connection.ts     # Connection management
│   │   └── platform.ts       # Platform-specific logic
│   ├── protocol/
│   │   ├── types.ts          # TypeScript types
│   │   ├── encoder.ts        # Message encoding
│   │   └── decoder.ts        # Message decoding
│   ├── store/
│   │   ├── database.ts       # SQLite connection
│   │   ├── migrations/       # Schema migrations
│   │   ├── changes.ts        # Change CRUD
│   │   ├── files.ts          # File CRUD
│   │   ├── hunks.ts          # Hunk CRUD
│   │   └── state.ts          # Review state
│   ├── tools/
│   │   ├── publish.ts        # MCP: publish_changes
│   │   ├── view.ts           # MCP: view_change
│   │   ├── retract.ts        # MCP: retract_change
│   │   └── modify.ts         # MCP: modify_change
│   └── sync/
│       ├── apply.ts          # Apply changes to files
│       └── handler.ts        # Handle user responses
├── tests/
│   ├── unit/
│   │   ├── transport.test.ts
│   │   ├── protocol.test.ts
│   │   └── store.test.ts
│   ├── integration/
│   │   ├── socket.test.ts
│   │   └── sync.test.ts
│   └── fixtures/
│       └── sample.diff       # jj diff format samples
├── package.json
└── tsconfig.json
```

## Testing Framework

### Neovim Plugin

Use **mini.test** (from mini.nvim) rather than plenary.test_harness because:
- Child process isolation for true statelessness
- Built-in screenshot assertions for precise UI verification
- Reference screenshot files for visual regression testing
- Works both headlessly and interactively
- No CI requirement

### Agent Harness Plugin

Use **Vitest** (or Node.js built-in test runner) because:
- Excellent TypeScript support
- Fast parallel execution
- Built-in mocking capabilities
- Great async/await support for socket testing

## Testing Philosophy

### Precise UI Testing

```lua
-- Example test structure
local child = MiniTest.new_child_neovim()

T['sidebar displays files correctly'] = function()
  -- Setup: Connect to mock server, load change
  child.lua([[require('ai-review').setup({socket = 'tests/mock.sock'})]])
  
  -- Trigger action
  child.type_keys('<leader>ar') -- Open AI review sidebar
  
  -- Verify exact screen state
  MiniTest.expect.reference_screenshot(child.get_screenshot())
  
  -- User can open this test file in real Neovim to see actual output
  -- Screenshot stored in: tests/screenshots/sidebar-displays-files--0-1
end
```

### Test Data Openable in Real Neovim

- All fixture files are real files in `tests/fixtures/`
- Test helper functions allow loading fixtures into actual buffers
- Tests can be run interactively with `:lua MiniTest.run_file()`
- Screenshots can be regenerated and inspected manually

### No File Creation

- Tests use temporary buffers, not files
- Fixtures are read-only
- Socket connections use ephemeral sockets in `/tmp`
- SQLite tests use `:memory:` database or temp files

---

## Edit Buffer / Review Flow (Settled Design)

This section records the design for the in-Neovim review experience. The
review-module layout proposed here is listed under "Planned additions" in the
Project Structure section above.

### Goal

Reviewing a file's proposed changes must feel like normal editing with full LSP
(diagnostics, completions, hover, code actions). Accept/reject happens at the
**hunk** level. CodeForge never writes to disk; the user saves normally.

### Core model: in-place swap

Reviewing a file = **temporarily loading the AI proposal `P` into the real file
buffer**, reviewing/editing it with full LSP, then resolving per-hunk
accept/reject against a snapshot of the user's prior edits `U`.

This is the only design that gives full LSP on the proposal, because LSP allows
only one open document per `file://` URI at a time and only `file://` URIs get
full project context. Keeping the proposal in the real buffer means the URI stays
continuously open and LSP never detaches.

It does **not** preclude the user having the same file open in multiple windows:
Neovim's `:edit <path>` on an already-open path reuses the existing buffer, so
duplicate-open is "many windows, one buffer" — all windows show the proposal
during review, which is correct.

### The versions

| symbol | meaning | source |
|--------|---------|--------|
| **O** | base — the file the AI diffed against | sent by agent harness change-set (`content`/`sync`) |
| **P** | proposal — base + hunk(s) applied | built by applying hunks to `O` |
| **U** | user's current unsaved buffer content | snapshotted on open, before loading `P` |
| **P′** | proposal + user's review edits | live buffer content at resolve time |

### Open flow (Enter on a file line in the sidebar)

1. Find the real buffer for `path` (already loaded → reuse; one buffer, possibly
   many windows). If not loaded anywhere, load it (hidden is fine).
2. **Snapshot `U`** = current buffer lines, into memory (per-change, per-file).
3. Build `P` by applying the change's hunks to `O`.
4. **Swap** buffer content → `P` (a `didChange`; LSP re-diagnoses `P` → full
   fidelity: diagnostics, completion, hover, code actions on the proposal).
5. Install virtual-fold extmarks for deletions (lines in `O` not in `P`),
   add-line highlights for additions, and per-hunk markers/keys.
6. Record that this file is under review.

### Deletion = virtual fold (restorable)

Deleted lines live as **extmark `virt_lines`** anchored at their position —
never real buffer text, invisible to LSP, never written to disk.

- Default **collapsed**: one virtual line, e.g.
  `─ 3 lines removed (<C-x>t to expand, <C-x>r to restore)`.
- `<C-x>t` toggles expand/collapse (swap the extmark's virt_lines).
- `<C-x>r` **restores**: promote those lines into real buffer lines at that position
  (they become part of `P′`, a local edit; other edits untouched).
- Keys are **configurable** (see Config), applied buffer-local.

### Accept / reject (per hunk)

A hunk defines a region `R` of `O`. At resolve time:

- **accept(hunk)** → `final[R] = merge3(O[R], P′[R], U[R])` via
  `git merge-file -p <U[R]> <O[R]> <P′[R]>`
  - `U[R] == O[R]` (you didn't touch it) → clean take of `P′`.
  - both touched → see Conflict resolution below.
  - idempotent: already-accepted → no-op.
- **reject(hunk)** → `final[R] = U[R]` (drop the AI change; your edits untouched).
  Mark `rejected`.
- Accepted/rejected hunks are removed from the review view (or faded `[A]`/`[R]`).

### Conflict resolution (first-class)

A conflict arises at accept time for a hunk region `R` when both sides edited the
same region: `P′[R] ≠ O[R]` **and** `U[R] ≠ O[R]`. Because in-place swap keeps
the live buffer as `P′` (not a merge result), we do **not** paste `git merge-file`'s
conflict-marker output into the live buffer. Instead:

1. **Detect** via `git merge-file -p U[R] O[R] P′[R]` exit code (per-region, so
   accepting one hunk doesn't force you through another's conflict).
2. **Resolve** with native Neovim 3-way diff (`:diffthis`), scoped to `R`:
   - `diffthis` on the live review buffer (`P′[R]`, writable, keeps full LSP).
   - scratch buffer: `U[R]` (ours — your pre-review edits, read-only).
   - scratch buffer: `O[R]` (base, read-only).
   - User resolves with `]c`/`[c` + `:diffget //2` (take ours/U) / `:diffget //3`
     (take theirs/P′), or hand-edits the live buffer. LSP stays live throughout.
3. **Confirm**: `final[R]` = live buffer's resolved `R`; `status='accepted'`;
   close scratch buffers; `diffoff`.

We use `git merge-file` only to *detect* conflict; Neovim's native diff does the
*resolution*. `git` is a hard dependency (matches every existing Neovim merge
plugin). No from-scratch diff3.

### Finish / dismiss

1. Assemble `final` from per-region picks (accepted→merged, rejected→`U`,
   untouched regions→`U`).
2. Load `final` into the buffer (another `didChange`; LSP re-diagnoses the real
   file).
3. Tear down extmarks/keymaps; clear review state for the file. Ephemeral — no
   LSP document left open beyond the real one.
4. The user `:w` when they want; CodeForge never writes.

### LSP

In-place swap means the real `file://` URI stays continuously open — LSP never
detaches, full project context throughout. "LSP as a server": we drive
`didChange`, consume diagnostics/completion, never persist a separate document.

- Auto-attach + diagnostics + code actions: free, since it's the real buffer.
- **Format-on-accept: dropped** (deferred).

### Config additions

```lua
require('codeforge').setup({
  keymaps = {
    next_change   = "<C-]>",
    prev_change   = "<C-[>",
    toggle_file  = "o",
    open_file     = "<CR>",   -- open review buffer for a file (low-cost default)
    toggle_fold   = "<C-x>t",  -- expand/collapse a deletion fold
    restore       = "<C-x>r",  -- promote a deletion to real lines
    accept_hunk   = "<C-x>a",  -- accept the hunk under the cursor
    reject_hunk   = "<C-x>j",  -- reject the hunk under the cursor
    resolve_hunk  = "<C-x>c",  -- enter 3-way diff resolve for a conflicted hunk
    dismiss       = "<C-x>d",  -- leave review (assemble final, restore buffer)
  },
})
```

### State additions (`state.lua`, per file in a change)

```lua
file.review = {
  real_bufnr,            -- the file buffer under review
  U            = {...},   -- snapshotted original lines
  O            = {...},   -- base (from change-set)
  hunks[i].status        -- 'pending'|'accepted'|'rejected'|'conflicted'
  deletions    = { id, anchor, lines, expanded },  -- virtual folds
  restored     = { id },                              -- promoted to real lines
}
```

### Proposed file layout (new code)

```
lua/codeforge/
  sidebar/element.lua   -- (existing) change/file/hunk tree
  review/
    buffer.lua   -- open/swap/dismiss; snapshot U; load P; assemble final
    diff.lua     -- virtual-fold extmarks (deletions), add-line hl, per-hunk marks
    apply.lua    -- per-hunk accept/reject; git merge-file 3-way; conflict detect
    resolve.lua  -- 3-way :diffthis sub-flow, diffget handlers, finalize region
    actions.lua  -- keymap handlers, find/open real buffer, wire review <-> sidebar
```

`lsp.lua` is intentionally absent — in-place swap gets LSP for free.

### Prerequisites / open data question

The merge needs **O** (base content the AI diffed against). The change-set schema
already has `content` on files and a `sync_response`; the agent harness should
send `O` with each change. If `O` is ever absent, we fall back to reconstructing
it from the current file by reversing the hunks — but only valid when the current
file equals `P`, so this is a degraded fallback, not the primary path.

