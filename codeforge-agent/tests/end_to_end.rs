//! End-to-end tests: the real `codeforge` binary against a real CodeForge editor.
//!
//! Every other test in this crate checks one side against its own model of the
//! protocol: `socket.rs` against a hand-written mock listener, `jj_build.rs`
//! against a real `jj` but with no server, and the Neovim suite against
//! hand-rolled Lua JSON clients. That leaves the *wire itself* unverified — a
//! field either side renames, an allowlist that drifts, a status shape that
//! stops matching. This file closes that gap by spawning a headless Neovim
//! running the actual plugin and driving it with the actual built CLI, so the
//! assertions are about bytes both sides really agree on.
//!
//! These are the slowest tests in the suite by nature (a Neovim process per
//! case), so the assertion count per started editor is deliberately high: one
//! arena seeds several files and exercises publish, status, and list against
//! the same instance.

#![cfg(unix)]

use std::io::Read;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

static COUNTER: AtomicU32 = AtomicU32::new(0);

///Path to the CodeForge Neovim plugin under test.
///
///Derived from this crate's manifest dir (`codeforge-agent/`) rather than the
///process cwd: `nextest` may run tests from anywhere, and a cwd-relative `..`
///would silently point at the wrong tree.
fn plugin_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("crate must have a parent directory")
        .join("codeforge-nvim")
}

///A throwaway arena: a jj repository, a Neovim runtime dir, and the socket.
///
///The Neovim process is killed on drop so a panicking assertion never leaks an
///editor that would hold the socket and wedge the next test.
struct Arena {
    dir: PathBuf,
    repo: PathBuf,
    home: PathBuf,
    sock: PathBuf,
    editor: Option<Child>,
}

impl Arena {
    fn new() -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("codeforge-e2e-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        let repo = dir.join("proj");
        let home = dir.join("home");
        std::fs::create_dir_all(&repo).expect("create arena repo");
        std::fs::create_dir_all(&home).expect("create arena home");

        let arena = Arena {
            sock: dir.join("cf.sock"),
            dir,
            repo,
            home,
            editor: None,
        };
        arena.jj(&["git", "init"]);
        arena.jj(&["config", "set", "--repo", "user.name", "Test"]);
        arena.jj(&["config", "set", "--repo", "user.email", "test@example.com"]);
        arena
    }

    fn jj(&self, args: &[&str]) {
        let out = Command::new("jj")
            .args(args)
            .current_dir(&self.repo)
            .output()
            .expect("run jj");
        assert!(
            out.status.success(),
            "jj {:?} failed: {}",
            args,
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn write(&self, rel: &str, contents: &str) {
        let full = self.repo.join(rel);
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent).expect("create parent dir");
        }
        std::fs::write(full, contents).expect("write file");
    }

    ///Commit the working copy and start a fresh change, returning its rev id.
    fn commit(&self, message: &str) -> String {
        self.jj(&["describe", "-m", message]);
        let id = self.rev_id("@");
        self.jj(&["new"]);
        id
    }

    fn rev_id(&self, rev: &str) -> String {
        let out = Command::new("jj")
            .args(["log", "-r", rev, "--no-graph", "-T", "commit_id"])
            .current_dir(&self.repo)
            .output()
            .expect("jj log");
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    ///Start a headless editor with the real plugin and wait for its socket.
    ///
    ///`vim.g.codeforge_setup` is the documented bootstrap for exactly this: the
    ///real auto-init path runs (so the test exercises `plugin/codeforge.lua`,
    ///not a bespoke harness) with the socket on an explicit path and session
    ///persistence off, since a leftover session file must never restore state
    ///the test did not seed.
    fn start_editor(&mut self) {
        let init = self.dir.join("init.lua");
        std::fs::write(
            &init,
            format!(
                "vim.o.runtimepath = {} .. ',' .. vim.o.runtimepath\n\
                 vim.g.codeforge_setup = {{ socket = {}, session = false }}\n",
                lua_str(&plugin_dir()),
                lua_str(&self.sock)
            ),
        )
        .expect("write init.lua");

        let child = Command::new("nvim")
            .arg("--headless")
            .arg("-u")
            .arg(&init)
            // Isolate state from the developer's real Neovim config and data.
            .env("XDG_CONFIG_HOME", self.home.join("config"))
            .env("XDG_DATA_HOME", self.home.join("data"))
            .env("XDG_STATE_HOME", self.home.join("state"))
            .current_dir(&self.repo)
            // stdin held open by this pipe, not inherited: a headless Neovim
            // whose stdin is at EOF exits at startup, before the socket exists.
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn nvim");
        self.editor = Some(child);

        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            // Probe only with a real request: the listener binds before it can
            // serve, so a successful `connect` is not readiness, and extra
            // half-open probes would count against the server's client cap.
            if self.try_info() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        panic!(
            "{}",
            self.editor_diagnostics("editor never became reachable on the socket")
        );
    }

    ///One `info` attempt; false while the server is not yet answering.
    fn try_info(&self) -> bool {
        self.cli_in(&self.repo)
            .args(["info", "--socket"])
            .arg(&self.sock)
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    }

    ///A CLI invocation run from `cwd`, with the socket selection scrubbed.
    ///
    ///`CODEFORGE_SOCKET` is removed so an inherited value cannot silently
    ///redirect the test to a different editor; tests that exercise the
    ///variable set it explicitly per invocation.
    fn cli_in(&self, cwd: &Path) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_codeforge"));
        cmd.current_dir(cwd).env_remove("CODEFORGE_SOCKET");
        cmd
    }

    ///Run the CLI from inside the arena repo, with the socket flag supplied.
    fn cli(&self, args: &[&str]) -> Output {
        self.cli_in(&self.repo)
            .args(args)
            .args(["--socket"])
            .arg(&self.sock)
            .output()
            .expect("run codeforge")
    }

    ///Run the CLI expecting success, returning stdout.
    fn cli_ok(&self, args: &[&str]) -> String {
        let out = self.cli(args);
        assert!(
            out.status.success(),
            "codeforge {args:?} failed ({}):\nstdout: {}\nstderr: {}",
            out.status,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).to_string()
    }

    ///Run the CLI expecting failure, returning stderr.
    fn cli_err(&self, args: &[&str]) -> String {
        let out = self.cli(args);
        assert!(
            !out.status.success(),
            "codeforge {args:?} unexpectedly succeeded:\n{}",
            String::from_utf8_lossy(&out.stdout)
        );
        String::from_utf8_lossy(&out.stderr).to_string()
    }

    ///Everything the editor said, for a failure report.
    fn editor_diagnostics(&mut self, context: &str) -> String {
        let mut report = format!("{context}\nsocket: {}\n", self.sock.display());
        report.push_str(&format!("socket exists: {}\n", self.sock.exists()));
        if let Some(mut child) = self.editor.take() {
            let _ = child.kill();
            let out = child.wait_with_output();
            match out {
                Ok(out) => {
                    report.push_str("--- nvim stderr ---\n");
                    report.push_str(&String::from_utf8_lossy(&out.stderr));
                    report.push_str("\n--- nvim stdout ---\n");
                    report.push_str(&String::from_utf8_lossy(&out.stdout));
                }
                Err(e) => report.push_str(&format!("could not collect nvim output: {e}\n")),
            }
        }
        report
    }
}

impl Drop for Arena {
    fn drop(&mut self) {
        if let Some(mut child) = self.editor.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

///Quote a path as a Lua string literal.
fn lua_str(path: &Path) -> String {
    format!("{:?}", path.to_string_lossy())
}

#[test]
fn publish_then_status_and_list_agree_with_the_real_editor() {
    // One editor, many assertions: starting Neovim is the expensive part, so
    // this covers the whole happy path and the shapes of every implemented op.
    let mut arena = Arena::new();
    arena.write("mod.lua", "one\ntwo\nthree\n");
    arena.write("gone.lua", "old\n");
    let base = arena.commit("base");
    arena.write("mod.lua", "one\nTWO\nthree\nfour\n");
    std::fs::remove_file(arena.repo.join("gone.lua")).expect("remove file");
    arena.write("new/nested.lua", "fresh\n");
    let tip = arena.commit("tip");
    arena.start_editor();

    // info: the receiver's own answers, not guesses.
    let info = arena.cli_ok(&["info"]);
    assert!(
        info.contains(&format!("cwd:     {}", arena.repo.display())),
        "info cwd must be the receiver's resolved working directory:\n{info}"
    );
    assert!(
        info.contains(&format!("socket:  {}", arena.sock.display())),
        "info socket must be the live address:\n{info}"
    );
    assert!(info.contains("changes: 0"), "nothing tracked yet:\n{info}");

    // publish: the real builder, the real preflight, the real admission.
    let stdout = arena.cli_ok(&[
        "publish",
        "--repo",
        &arena.repo.to_string_lossy(),
        "--from",
        &base,
        "--to",
        &tip,
        "--title",
        "End to end",
    ]);
    let change_id = stdout
        .lines()
        .next()
        .expect("receipt id")
        .trim()
        .to_string();
    assert!(
        change_id.starts_with("cf-"),
        "receipt must carry the editor-assigned id, got {change_id:?}"
    );

    // status: every file classified, and hunk ids match the receipt's claim.
    let status = arena.cli_ok(&["status", "--id", &change_id]);
    assert!(
        status.contains(&format!("{change_id}  pending  under_review=true")),
        "a freshly published change is pending and under review:\n{status}"
    );
    let mod_row = status
        .lines()
        .find(|l| l.contains("mod.lua"))
        .unwrap_or_else(|| panic!("mod.lua missing from status:\n{status}"));
    assert!(
        mod_row.contains("modified") && mod_row.contains("pending, pending"),
        "a modified file reports per-hunk outcomes:\n{mod_row}"
    );
    let added_row = status
        .lines()
        .find(|l| l.contains("nested.lua"))
        .unwrap_or_else(|| panic!("added file missing from status:\n{status}"));
    assert!(
        added_row.contains("added") && added_row.contains("pending"),
        "an added file reports a whole-file decision:\n{added_row}"
    );
    let deleted_row = status
        .lines()
        .find(|l| l.contains("gone.lua"))
        .unwrap_or_else(|| panic!("deleted file missing from status:\n{status}"));
    assert!(
        deleted_row.contains("deleted") && deleted_row.contains("pending"),
        "a deleted file reports a whole-file decision:\n{deleted_row}"
    );

    // list: the change is discoverable through pagination, not just by id.
    let listed = arena.cli_ok(&["list"]);
    assert!(
        listed.contains(&change_id) && listed.contains("End to end"),
        "list must rediscover the published change:\n{listed}"
    );
    assert!(
        listed.contains("pending"),
        "a tracked change lists as pending:\n{listed}"
    );
}

#[test]
fn a_second_publish_of_a_tracked_path_is_refused_with_both_paths_named() {
    // Admission is create-only per path, and the refusal must survive the real
    // wire: this is the error shape an agent loop branches on, and it is only
    // checked against hand-written mocks elsewhere.
    let mut arena = Arena::new();
    arena.write("a.lua", "one\n");
    arena.write("b.lua", "two\n");
    let base = arena.commit("base");
    arena.write("a.lua", "ONE\n");
    arena.write("b.lua", "TWO\n");
    let tip = arena.commit("tip");
    arena.start_editor();

    arena.cli_ok(&[
        "publish",
        "--repo",
        &arena.repo.to_string_lossy(),
        "--from",
        &base,
        "--to",
        &tip,
    ]);

    let stderr = arena.cli_err(&[
        "publish",
        "--repo",
        &arena.repo.to_string_lossy(),
        "--from",
        &base,
        "--to",
        &tip,
    ]);
    assert!(
        stderr.contains("invalid_proposal"),
        "the refusal must be reported as a protocol error:\n{stderr}"
    );
    // Both paths in one reply: learning one bad path per attempt would make a
    // multi-file retry loop quadratic.
    assert!(
        stderr.contains("a.lua") && stderr.contains("b.lua"),
        "every refused path must be named in one reply:\n{stderr}"
    );
    assert!(
        stderr.contains("already tracked"),
        "the reason must say why:\n{stderr}"
    );
}

#[test]
fn a_modified_target_missing_on_disk_is_refused_though_the_agent_has_it() {
    // The asymmetry this test exists for: the *agent's* checkout and the
    // *receiver's* disk are different, and the receiver is authoritative. A
    // path that exists in the source revision but not in the editor's cwd must
    // be refused, and the local preflight cannot know that.
    let mut arena = Arena::new();
    arena.write("present.lua", "one\n");
    arena.write("vanished.lua", "one\n");
    let base = arena.commit("base");
    arena.write("present.lua", "ONE\n");
    arena.write("vanished.lua", "ONE\n");
    let tip = arena.commit("tip");

    // Delete it from disk *after* building the revision range, so the jj range
    // still describes a modified file the receiver cannot find as a regular
    // file. This mirrors jj history outrunning the editor's checkout.
    std::fs::remove_file(arena.repo.join("vanished.lua")).expect("remove");
    arena.start_editor();

    let stderr = arena.cli_err(&[
        "publish",
        "--repo",
        &arena.repo.to_string_lossy(),
        "--from",
        &base,
        "--to",
        &tip,
    ]);
    assert!(
        stderr.contains("invalid_proposal") && stderr.contains("vanished.lua"),
        "a modified target absent from the receiver's disk must be named:\n{stderr}"
    );
    assert!(
        stderr.contains("regular file"),
        "the reason must name the actual requirement:\n{stderr}"
    );
}

#[test]
fn dry_run_reports_and_admits_nothing_then_a_real_publish_succeeds() {
    // The dry run is an agent's pre-flight: it must be strictly read-only,
    // which is checked against the receiver rather than assumed. (That it
    // encodes the same bytes as a real publish is guaranteed structurally —
    // both paths share `body` — not asserted here.)
    let mut arena = Arena::new();
    arena.write("f.lua", "one\ntwo\n");
    let base = arena.commit("base");
    arena.write("f.lua", "one\nTWO\nthree\n");
    let tip = arena.commit("tip");
    arena.start_editor();

    let dry = arena.cli_ok(&[
        "publish",
        "--dry-run",
        "--repo",
        &arena.repo.to_string_lossy(),
        "--from",
        &base,
        "--to",
        &tip,
    ]);
    assert!(dry.trim().is_empty(), "a dry run prints nothing on stdout");
    assert!(
        arena.cli_ok(&["info"]).contains("changes: 0"),
        "a dry run must not admit anything"
    );

    let real = arena.cli_ok(&[
        "publish",
        "--repo",
        &arena.repo.to_string_lossy(),
        "--from",
        &base,
        "--to",
        &tip,
    ]);
    assert!(
        real.trim().starts_with("cf-"),
        "the real publish returns an id"
    );
    assert!(
        arena.cli_ok(&["info"]).contains("changes: 1"),
        "the real publish admits exactly one change"
    );
}

#[test]
fn the_env_var_is_honoured_as_a_fallback_but_a_flag_still_wins() {
    // Agents set the socket once in the environment. If the variable name the
    // binary reads drifts from the one documented to agents, every call fails
    // with a confusing connect error, which is a silent, total breakage.
    let mut arena = Arena::new();
    arena.start_editor();
    let bin = env!("CARGO_BIN_EXE_codeforge");

    let via_env = Command::new(bin)
        .arg("info")
        .current_dir(&arena.repo)
        .env("CODEFORGE_SOCKET", &arena.sock)
        .output()
        .expect("run via env");
    assert!(
        via_env.status.success(),
        "a documented env var must resolve the socket, got: {}",
        String::from_utf8_lossy(&via_env.stderr)
    );

    // A wrong env var plus a correct flag must still work: the flag is the
    // most specific signal and must not be overridden by the environment.
    let flag_wins = Command::new(bin)
        .args(["info", "--socket"])
        .arg(&arena.sock)
        .current_dir(&arena.repo)
        .env("CODEFORGE_SOCKET", "/nonexistent/definitely-not-here.sock")
        .output()
        .expect("run via flag");
    assert!(
        flag_wins.status.success(),
        "--socket must beat a bad env var, got: {}",
        String::from_utf8_lossy(&flag_wins.stderr)
    );
}

#[test]
fn a_hunk_description_is_admitted_verbatim_and_a_control_character_is_refused() {
    // Hunk descriptions are display metadata with their own allowlist on the
    // receiver. This is the seam where the agent's local preflight and the
    // server's validation can disagree, so both halves are probed from here.
    let mut arena = Arena::new();
    // A `modified` publish needs the target as a real regular file on the
    // receiver's disk; the wire request below supplies its own base.
    arena.write("d.lua", "one\ntwo\n");
    arena.start_editor();

    // A description carried on the wire is admitted and stored verbatim.
    let request = r#"{"op":"publish","proposal":{"title":"desc","files":[{"path":"d.lua","status":"modified","base":["one","two"],"hunks":[{"old_start":2,"old_lines":1,"new_start":2,"new_lines":1,"lines":["-two","+TWO"],"description":"rename row"}]}]}}"#;
    let reply = direct(&arena.sock, request);
    assert!(
        reply.contains(r#""ok":true"#),
        "a clean description must be admitted: {reply}"
    );
    // The admission is visible to a normal client afterwards, and the id the
    // receipt named is the one `list` reports.
    let receipt: serde_json::Value = serde_json::from_str(&reply).expect("reply is JSON");
    let change_id = receipt["result"]["id"].as_str().expect("receipt id");
    assert!(
        arena.cli_ok(&["list"]).contains(change_id),
        "the admitted change must be listable by its receipt id"
    );

    // The same request with a tab in the description must be refused with its
    // reason, since it would otherwise render as more than one sidebar row. A
    // raw tab is used (not an escape): the decoder must see the character it
    // would actually render.
    let bad = request.replace("rename row", "rename\trow");
    let refused = direct(&arena.sock, &bad);
    assert!(
        refused.contains("control characters"),
        "a control character in a description must be refused with its reason: {refused}"
    );
}

///Send one raw request frame to the socket and return the reply text.
///
///Used only where the test needs to drive the wire directly (a shape the CLI
///has no flag for); everything else goes through the real binary.
fn direct(sock: &Path, body: &str) -> String {
    use std::io::Write;
    let mut stream =
        UnixStream::connect(sock).unwrap_or_else(|e| panic!("connect {}: {e}", sock.display()));
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("set read timeout");
    stream
        .write_all(format!("{body}\n").as_bytes())
        .expect("write request");
    stream.flush().expect("flush");
    let mut reply = String::new();
    stream.read_to_string(&mut reply).expect("read reply");
    reply
}
