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
│              Opencode Plugin                   │
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

**Opencode Plugin:**
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
- Opencode: Use Node.js test runner (built-in) or Vitest
- Neovim: Use mini.test with child process isolation
- Create test fixtures for sample jj diffs

### Phase 2: Core Review Flow + UI Testing

**Opencode Plugin:**
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

**Opencode Plugin:**
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
- [ ] State persistence (SQLite via opencode):
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

```
ai-review/
├── opencode-plugin/
│   ├── src/
│   │   ├── index.ts              # Entry point
│   │   ├── transport/
│   │   │   ├── server.ts         # Socket server
│   │   │   ├── connection.ts     # Connection management
│   │   │   └── platform.ts       # Platform-specific logic
│   │   ├── protocol/
│   │   │   ├── types.ts          # TypeScript types
│   │   │   ├── encoder.ts        # Message encoding
│   │   │   └── decoder.ts        # Message decoding
│   │   ├── store/
│   │   │   ├── database.ts       # SQLite connection
│   │   │   ├── migrations/       # Schema migrations
│   │   │   ├── changes.ts        # Change CRUD
│   │   │   ├── files.ts          # File CRUD
│   │   │   ├── hunks.ts          # Hunk CRUD
│   │   │   └── state.ts          # Review state
│   │   ├── tools/
│   │   │   ├── publish.ts        # MCP: publish_changes
│   │   │   ├── view.ts           # MCP: view_change
│   │   │   ├── retract.ts        # MCP: retract_change
│   │   │   └── modify.ts         # MCP: modify_change
│   │   └── sync/
│   │       ├── apply.ts          # Apply changes to files
│   │       └── handler.ts        # Handle user responses
│   ├── tests/
│   │   ├── unit/
│   │   │   ├── transport.test.ts
│   │   │   ├── protocol.test.ts
│   │   │   └── store.test.ts
│   │   ├── integration/
│   │   │   ├── socket.test.ts
│   │   │   └── sync.test.ts
│   │   └── fixtures/
│   │       └── sample.diff       # jj diff format samples
│   ├── package.json
│   └── tsconfig.json
│
├── nvim-plugin/
│   ├── lua/ai-review/
│   │   ├── init.lua              # Entry point
│   │   ├── config.lua            # Configuration
│   │   ├── transport/
│   │   │   ├── client.lua        # Socket client
│   │   │   └── connection.lua    # Connection management
│   │   ├── protocol/
│   │   │   ├── types.lua         # Type definitions
│   │   │   ├── encoder.lua       # Message encoding
│   │   │   └── decoder.lua       # Message decoding
│   │   ├── sidebar/
│   │   │   ├── init.lua          # Sidebar setup
│   │   │   ├── component.lua     # dap-ui component
│   │   │   ├── renderer.lua      # Tree rendering
│   │   │   └── actions.lua       # User actions
│   │   ├── review/
│   │   │   ├── buffer.lua        # Review buffer management
│   │   │   ├── hunks.lua         # Hunk display (gitsigns)
│   │   │   ├── actions.lua       # Accept/reject handlers
│   │   │   └── lsp.lua           # LSP integration
│   │   └── state/
│   │       ├── persistence.lua   # State persistence
│   │       └── recovery.lua      # Crash recovery
│   ├── tests/
│   │   ├── test_transport.lua    # Socket client tests
│   │   ├── test_protocol.lua     # Protocol tests
│   │   ├── test_sidebar.lua      # Sidebar UI tests
│   │   ├── test_review.lua       # Review flow tests
│   │   ├── test_state.lua        # State tests
│   │   ├── helpers.lua           # Test utilities
│   │   ├── minimal_init.lua      # Test initialization
│   │   ├── fixtures/
│   │   │   ├── sample.diff
│   │   │   └── sample.lua        # Fixture files
│   │   └── screenshots/          # Reference screenshots
│   │       └── .gitkeep
│   └── Makefile
│
└── README.md                     # Setup instructions
```

## Testing Framework

### Neovim Plugin

Use **mini.test** (from mini.nvim) rather than plenary.test_harness because:
- Child process isolation for true statelessness
- Built-in screenshot assertions for precise UI verification
- Reference screenshot files for visual regression testing
- Works both headlessly and interactively
- No CI requirement

### Opencode Plugin

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
