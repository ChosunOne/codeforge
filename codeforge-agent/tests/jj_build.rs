//! Adversarial tests for building a publish proposal from a jj revision range.
//!
//! These run against **real jj repositories** created in temp dirs, not canned
//! diff text. The properties under test (status classification, the
//! base-coordinate `old_start` convention, and reconstruction) are exactly
//! where a hand-written fixture would encode my misunderstanding instead of the
//! real tool's behaviour.

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

use codeforge_agent::jj::{self, BuildOptions};
use codeforge_agent::wire::{FileStatus, Hunk, Proposal};

static COUNTER: AtomicU32 = AtomicU32::new(0);

///A throwaway jj repo, removed on drop.
struct TempRepo {
    path: PathBuf,
}

impl TempRepo {
    fn new() -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("codeforge-jj-{}-{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp repo dir");
        let repo = TempRepo { path };
        repo.jj(&["git", "init"]);
        // Identity so commits are attributable and jj never blocks on input.
        repo.jj(&["config", "set", "--repo", "user.name", "Test"]);
        repo.jj(&["config", "set", "--repo", "user.email", "test@example.com"]);
        repo
    }

    fn jj(&self, args: &[&str]) {
        let out = Command::new("jj")
            .args(args)
            .current_dir(&self.path)
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
        let full = self.path.join(rel);
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent).expect("create parent dir");
        }
        std::fs::write(full, contents).expect("write file");
    }

    ///Commit the working copy and start a fresh empty change, returning the
    ///revision id of the commit just made.
    fn commit(&self, message: &str) -> String {
        self.jj(&["describe", "-m", message]);
        let id = self.rev_id("@");
        self.jj(&["new"]);
        id
    }

    fn rev_id(&self, rev: &str) -> String {
        let out = Command::new("jj")
            .args(["log", "-r", rev, "--no-graph", "-T", "commit_id"])
            .current_dir(&self.path)
            .output()
            .expect("jj log");
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn opts(repo: &TempRepo, from: &str, to: &str) -> BuildOptions {
    BuildOptions {
        repo: repo.path().to_path_buf(),
        from: from.to_string(),
        to: to.to_string(),
        // The receiver's cwd is the repo root in these tests.
        path_filter: None,
        excludes: Vec::new(),
    }
}

///Apply a proposal's hunks to its base, mirroring the receiver's semantics.
fn reconstruct(file: &codeforge_agent::wire::FileChange) -> Vec<String> {
    let base = file.base.clone().unwrap_or_default();
    let mut hunks: Vec<&Hunk> = file.hunks.iter().collect();
    hunks.sort_by_key(|h| h.old_start);
    let mut out: Vec<String> = Vec::new();
    let mut cursor = 0usize; // 0-based index into base
    for h in hunks {
        let start = (h.old_start - 1) as usize;
        while cursor < start {
            out.push(base[cursor].clone());
            cursor += 1;
        }
        for line in &h.lines {
            if let Some(rest) = line.strip_prefix('+') {
                out.push(rest.to_string());
            }
        }
        cursor += h.old_lines as usize;
    }
    while cursor < base.len() {
        out.push(base[cursor].clone());
        cursor += 1;
    }
    out
}

fn file<'a>(p: &'a Proposal, name: &str) -> &'a codeforge_agent::wire::FileChange {
    p.files.iter().find(|f| f.path == name).unwrap_or_else(|| {
        panic!(
            "no file {name} in {:?}",
            p.files.iter().map(|f| &f.path).collect::<Vec<_>>()
        )
    })
}

#[test]
fn a_new_file_is_added_with_no_base_and_one_hunk() {
    let repo = TempRepo::new();
    repo.write("keep.txt", "k\n");
    let base = repo.commit("base");
    repo.write("new.txt", "a\nb\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "new.txt");
    assert_eq!(f.status, FileStatus::Added);
    assert!(f.base.is_none(), "an added file must not carry a base");
    assert_eq!(f.hunks.len(), 1);
    assert_eq!(f.hunks[0].old_lines, 0);
    assert_eq!(
        f.hunks[0].old_start, 1,
        "an added-file hunk starts at base line 1"
    );
    assert_eq!(reconstruct(f), vec!["a", "b"]);
}

#[test]
fn a_removed_file_is_deleted_with_its_full_base() {
    let repo = TempRepo::new();
    repo.write("gone.txt", "x\ny\n");
    let base = repo.commit("base");
    std::fs::remove_file(repo.path().join("gone.txt")).expect("remove");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "gone.txt");
    assert_eq!(f.status, FileStatus::Deleted);
    assert_eq!(
        f.base.as_deref(),
        Some(&["x".to_string(), "y".to_string()][..])
    );
    assert_eq!(f.hunks.len(), 1);
    assert_eq!(f.hunks[0].new_lines, 0);
    assert!(reconstruct(f).is_empty());
}

#[test]
fn a_replacement_hunk_reconstructs_the_new_content() {
    let repo = TempRepo::new();
    repo.write("m.txt", "one\ntwo\nthree\n");
    let base = repo.commit("base");
    repo.write("m.txt", "one\nTWO\nthree\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "m.txt");
    assert_eq!(f.status, FileStatus::Modified);
    assert_eq!(
        f.base.as_deref(),
        Some(&["one".to_string(), "two".to_string(), "three".to_string()][..])
    );
    assert_eq!(f.hunks.len(), 1);
    assert_eq!(
        f.hunks[0].old_start, 2,
        "the changed region begins at base line 2"
    );
    assert_eq!(f.hunks[0].old_lines, 1);
    assert_eq!(reconstruct(f), vec!["one", "TWO", "three"]);
}

#[test]
fn an_insertion_before_the_first_line_uses_old_start_one_with_zero_lines() {
    // The subtle one: CodeForge wants the 1-indexed base line the region begins
    // AT, so an insertion *before* line 1 is old_start=1, old_lines=0. git's
    // `@@ -0,0 +1,N` header describes the same edit, so copying header numbers
    // would produce a wrong (or rejected) hunk.
    let repo = TempRepo::new();
    repo.write("i.txt", "a\nb\n");
    let base = repo.commit("base");
    repo.write("i.txt", "new\na\nb\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "i.txt");
    assert_eq!(f.hunks.len(), 1);
    assert_eq!(f.hunks[0].old_start, 1);
    assert_eq!(f.hunks[0].old_lines, 0);
    assert_eq!(reconstruct(f), vec!["new", "a", "b"]);
}

#[test]
fn an_insertion_after_the_last_line_reconstructs() {
    let repo = TempRepo::new();
    repo.write("t.txt", "a\nb\n");
    let base = repo.commit("base");
    repo.write("t.txt", "a\nb\nlast\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "t.txt");
    assert_eq!(f.hunks.len(), 1);
    assert_eq!(reconstruct(f), vec!["a", "b", "last"]);
}

#[test]
fn adjacent_delete_and_insert_coalesce_into_one_hunk() {
    // The receiver rejects overlapping or shared-start base ranges, so an
    // edit reported as separate delete/insert ops must be merged into a single
    // region rather than emitted as two hunks that share a start.
    let repo = TempRepo::new();
    repo.write("c.txt", "one\ntwo\nthree\n");
    let base = repo.commit("base");
    repo.write("c.txt", "one\n2\n3\nfour\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "c.txt");
    assert_eq!(
        f.hunks.len(),
        1,
        "expected one coalesced hunk, got {:?}",
        f.hunks
    );
    assert_eq!(reconstruct(f), vec!["one", "2", "3", "four"]);
}

#[test]
fn widely_separated_edits_produce_separate_hunks() {
    let repo = TempRepo::new();
    let mut original = String::new();
    for i in 1..=20 {
        original.push_str(&format!("line {i}\n"));
    }
    repo.write("w.txt", &original);
    let base = repo.commit("base");
    let edited = original
        .replace("line 2\n", "LINE 2\n")
        .replace("line 18\n", "LINE 18\n");
    repo.write("w.txt", &edited);
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "w.txt");
    assert_eq!(f.hunks.len(), 2, "expected two hunks, got {:?}", f.hunks);
    assert!(f.hunks[0].old_start < f.hunks[1].old_start);
    assert_eq!(reconstruct(f), edited.lines().collect::<Vec<_>>());
}

#[test]
fn an_unchanged_file_produces_no_entry() {
    let repo = TempRepo::new();
    repo.write("same.txt", "s\n");
    repo.write("other.txt", "o\n");
    let base = repo.commit("base");
    repo.write("other.txt", "O\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    assert_eq!(p.files.len(), 1, "unchanged files must be omitted");
    assert_eq!(p.files[0].path, "other.txt");
}

#[test]
fn a_path_filter_limits_the_proposal_without_prefix_matching_siblings() {
    // The receiver's cwd may be a subdirectory, so paths are selected by
    // prefix — but "codeforge-agent" must not also match "codeforge-agentx".
    let repo = TempRepo::new();
    repo.write("pkg/one.txt", "1\n");
    repo.write("pkgx/two.txt", "2\n");
    let base = repo.commit("base");
    repo.write("pkg/one.txt", "ONE\n");
    repo.write("pkgx/two.txt", "TWO\n");
    let tip = repo.commit("tip");

    let mut o = opts(&repo, &base, &tip);
    o.path_filter = Some("pkg/".to_string());
    let p = jj::build_proposal(&o).expect("build");
    assert_eq!(
        p.files.len(),
        1,
        "got {:?}",
        p.files.iter().map(|f| &f.path).collect::<Vec<_>>()
    );
    assert_eq!(p.files[0].path, "pkg/one.txt");
}

#[test]
fn excluded_prefixes_are_dropped_without_prefix_matching_siblings() {
    // An exclusion selects a directory, but must not also drop a sibling whose
    // name merely starts with the same characters.
    let repo = TempRepo::new();
    repo.write("docs/guide.md", "a\n");
    repo.write("docsx/keep.md", "b\n");
    repo.write("src/main.rs", "c\n");
    let base = repo.commit("base");
    repo.write("docs/guide.md", "A\n");
    repo.write("docsx/keep.md", "B\n");
    repo.write("src/main.rs", "C\n");
    let tip = repo.commit("tip");

    let mut o = opts(&repo, &base, &tip);
    o.excludes = vec!["docs/".to_string()];
    let p = jj::build_proposal(&o).expect("build");
    let got: Vec<&String> = p.files.iter().map(|f| &f.path).collect();
    assert!(
        !got.iter().any(|p| p.starts_with("docs/")),
        "docs/ must be dropped, got {got:?}"
    );
    assert!(
        got.iter().any(|p| *p == "docsx/keep.md"),
        "a sibling sharing the prefix must survive, got {got:?}"
    );
    assert!(got.iter().any(|p| *p == "src/main.rs"));
}

#[test]
fn an_excluded_path_is_absent_from_the_proposal_entirely() {
    // The receiver refuses a `modified` target that does not exist on its disk,
    // and admission is all-or-nothing, so an unpublishable path must be
    // removed here rather than failing the whole change set later.
    let repo = TempRepo::new();
    repo.write("PLAN.md", "doc\n");
    repo.write("code.rs", "x\n");
    let base = repo.commit("base");
    repo.write("PLAN.md", "DOC\n");
    repo.write("code.rs", "Y\n");
    let tip = repo.commit("tip");

    let mut o = opts(&repo, &base, &tip);
    o.excludes = vec!["PLAN.md".to_string()];
    let p = jj::build_proposal(&o).expect("build");
    assert_eq!(
        p.files.len(),
        1,
        "got {:?}",
        p.files.iter().map(|f| &f.path).collect::<Vec<_>>()
    );
    assert_eq!(p.files[0].path, "code.rs");
}

#[test]
fn every_hunk_keeps_its_coordinates_consistent_with_its_lines() {
    // The receiver validates that `-` lines equal old_lines and `+` lines equal
    // new_lines, and that removed lines match the base. Checking the invariant
    // here means a builder bug is caught locally rather than as a server
    // rejection after a round trip.
    let repo = TempRepo::new();
    repo.write("v.txt", "a\nb\nc\nd\ne\n");
    let base = repo.commit("base");
    repo.write("v.txt", "a\nB\nc\nD\nE\nf\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    let f = file(&p, "v.txt");
    let base_lines = f.base.as_ref().expect("modified file has a base");
    for h in &f.hunks {
        let minus = h.lines.iter().filter(|l| l.starts_with('-')).count() as u32;
        let plus = h.lines.iter().filter(|l| l.starts_with('+')).count() as u32;
        assert_eq!(minus, h.old_lines, "old_lines mismatch in {h:?}");
        assert_eq!(plus, h.new_lines, "new_lines mismatch in {h:?}");

        // Removed lines must equal the base lines they claim to replace.
        let mut row = (h.old_start - 1) as usize;
        for line in &h.lines {
            if let Some(rest) = line.strip_prefix('-') {
                assert_eq!(
                    rest,
                    base_lines[row],
                    "removed line does not match base line {} in {h:?}",
                    row + 1
                );
                row += 1;
            }
        }
    }
}

#[test]
fn a_path_outside_the_repo_is_not_silently_included() {
    // Defensive: the receiver canonicalizes and containment-checks, so a
    // builder that emitted an escapist path would be rejected late. Refuse it
    // here instead, where the message can name the problem.
    let repo = TempRepo::new();
    repo.write("ok.txt", "x\n");
    let base = repo.commit("base");
    repo.write("ok.txt", "y\n");
    let tip = repo.commit("tip");

    let p = jj::build_proposal(&opts(&repo, &base, &tip)).expect("build");
    for f in &p.files {
        assert!(!f.path.starts_with('/'), "absolute path leaked: {}", f.path);
        assert!(!f.path.contains(".."), "escaping path leaked: {}", f.path);
    }
}
