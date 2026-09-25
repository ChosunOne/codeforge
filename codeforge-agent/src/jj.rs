//! Build a CodeForge publish proposal from a jj revision range.
//!
//! Content comes from `jj file show`, not from parsing diff text. Diff output
//! carries traps that are easy to mishandle — `\ No newline at end of file`
//! markers, paths with spaces, and git's `@@ -0,0` header meaning "after line
//! 0" — whereas `file show` gives the exact bytes the receiver will compare
//! against. The line diff is then computed here, where the convention is under
//! our control.
//!
//! Two conventions this module exists to get right:
//!
//! 1. `old_start` is the 1-indexed **base** line the region begins at, so an
//!    insertion before base line 1 is `old_start = 1, old_lines = 0`. git
//!    writes the same edit as `@@ -0,0`, which is not that number.
//! 2. Adjacent delete/insert pairs coalesce into a single hunk. The receiver
//!    refuses overlapping or shared-start base ranges, so emitting two hunks
//!    for one contiguous edit would be rejected.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::wire::{FileChange, FileStatus, Hunk, Proposal};

///Options for [`build_proposal`].
#[derive(Debug, Clone)]
pub struct BuildOptions {
    ///Repository root to run `jj` in.
    pub repo: PathBuf,
    ///Base revision: what the receiver's checkout is expected to match.
    pub from: String,
    ///Tip revision: the content being proposed.
    pub to: String,
    ///Optional repo-relative prefix; only matching paths are included.
    ///
    ///A plain prefix match on this string, so `pkg/` selects `pkg/…` without
    ///also selecting a sibling named `pkgx`.
    pub path_filter: Option<String>,
    ///Repo-relative prefixes to drop from the proposal.
    ///
    ///Needed because a path can be part of the diff yet not publishable: a
    ///receiver whose checkout lacks a file requires an `added` publish, and
    ///documentation is often deliberately kept out of review.
    pub excludes: Vec<String>,
}

///Why building a proposal failed.
#[derive(Debug)]
pub enum BuildError {
    ///`jj` could not be run.
    Spawn { source: std::io::Error },
    ///A `jj` invocation exited non-zero.
    Command { args: Vec<String>, stderr: String },
    ///A path reported by jj escaped the repository.
    UnsafePath { path: String },
}

impl std::fmt::Display for BuildError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BuildError::Spawn { source } => write!(f, "cannot run jj: {source}"),
            BuildError::Command { args, stderr } => {
                write!(f, "jj {} failed: {}", args.join(" "), stderr.trim())
            }
            BuildError::UnsafePath { path } => {
                write!(f, "refusing to publish an unsafe path: {path}")
            }
        }
    }
}

impl std::error::Error for BuildError {}

///Run `jj` in `repo`, returning stdout on success.
fn jj(repo: &Path, args: &[&str]) -> Result<String, BuildError> {
    let out = Command::new("jj")
        .args(args)
        .current_dir(repo)
        .output()
        .map_err(|e| BuildError::Spawn { source: e })?;
    if !out.status.success() {
        return Err(BuildError::Command {
            args: args.iter().map(|s| s.to_string()).collect(),
            stderr: String::from_utf8_lossy(&out.stderr).to_string(),
        });
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

///Split file content into lines the way the receiver's `base`/`lines` model
///does: one entry per line, with a trailing newline not producing an extra
///empty entry (matching `vim.split` after the trailing separator is dropped).
fn to_lines(content: &str) -> Vec<String> {
    if content.is_empty() {
        return Vec::new();
    }
    let mut lines: Vec<String> = content.split('\n').map(|s| s.to_string()).collect();
    if lines.last().map(|s| s.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines
}

///Shortest-edit-script line diff, coalescing adjacent delete/insert pairs.
///
///Returns `(base_start_index, base_len, new_start_index, new_len)` tuples with
///0-based indices, ready to convert to the wire's 1-based `old_start`.
fn diff_regions(old: &[String], new: &[String]) -> Vec<(usize, usize, usize, usize)> {
    // Longest common subsequence via a full table: change sets here are
    // file-sized, so clarity beats the memory of a smarter algorithm.
    let n = old.len();
    let m = new.len();
    let mut lcs = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if old[i] == new[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    // Walk the table, emitting changed runs.
    let mut regions = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n || j < m {
        if i < n && j < m && old[i] == new[j] {
            i += 1;
            j += 1;
            continue;
        }
        let (i0, j0) = (i, j);
        // Advance until the next anchor (a position the LCS keeps).
        while i < n || j < m {
            if i < n && j < m && old[i] == new[j] {
                break;
            }
            if j < m && (i >= n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                j += 1;
            } else if i < n {
                i += 1;
            } else {
                break;
            }
        }
        // Merge with the previous region when they are adjacent, which is what
        // makes one contiguous edit a single hunk.
        if let Some(last) = regions.last_mut() {
            let (_, b_end, _, o_end): &mut (usize, usize, usize, usize) = last;
            if *b_end == i0 && *o_end == j0 {
                *b_end = i;
                *o_end = j;
                continue;
            }
        }
        regions.push((i0, i, j0, j));
    }
    regions
}

///Build hunks transforming `old` into `new`, in the wire's convention.
fn hunks_from(old: &[String], new: &[String]) -> Vec<Hunk> {
    diff_regions(old, new)
        .into_iter()
        .filter_map(|(b0, b1, o0, o1)| {
            let mut lines: Vec<String> = Vec::new();
            for l in &old[b0..b1] {
                lines.push(format!("-{l}"));
            }
            for l in &new[o0..o1] {
                lines.push(format!("+{l}"));
            }
            if lines.is_empty() {
                return None;
            }
            Some(Hunk {
                old_start: (b0 + 1) as u32,
                old_lines: (b1 - b0) as u32,
                new_start: (o0 + 1) as u32,
                new_lines: (o1 - o0) as u32,
                lines,
                description: None,
            })
        })
        .collect()
}

///Paths changed between `from` and `to`, repo-relative.
fn changed_paths(repo: &Path, from: &str, to: &str) -> Result<Vec<String>, BuildError> {
    let raw = jj(repo, &["diff", "--name-only", "--from", from, "--to", to])?;
    Ok(raw
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect())
}

///Read a file's content at `rev`, or `None` when it does not exist there.
fn show(repo: &Path, rev: &str, path: &str) -> Result<Option<Vec<String>>, BuildError> {
    let out = Command::new("jj")
        .args(["file", "show", "-r", rev, path])
        .current_dir(repo)
        .output()
        .map_err(|e| BuildError::Spawn { source: e })?;
    if !out.status.success() {
        // A missing file is a legitimate answer (added/deleted), not an error.
        return Ok(None);
    }
    Ok(Some(to_lines(&String::from_utf8_lossy(&out.stdout))))
}

///Refuse a path that could escape the receiver's working directory.
///
///The receiver canonicalizes and containment-checks too, but failing here
///names the problem at build time rather than as a late rejection.
fn check_path(path: &str) -> Result<(), BuildError> {
    if path.starts_with('/') || path.contains("..") || path.contains('\0') {
        return Err(BuildError::UnsafePath {
            path: path.to_string(),
        });
    }
    Ok(())
}

///Build a proposal describing `from` → `to`.
pub fn build_proposal(opts: &BuildOptions) -> Result<Proposal, BuildError> {
    let mut files = Vec::new();
    for path in changed_paths(&opts.repo, &opts.from, &opts.to)? {
        if let Some(filter) = &opts.path_filter {
            if !path.starts_with(filter.as_str()) {
                continue;
            }
        }
        if opts.excludes.iter().any(|e| path.starts_with(e.as_str())) {
            continue;
        }
        check_path(&path)?;
        let old = show(&opts.repo, &opts.from, &path)?;
        let new = show(&opts.repo, &opts.to, &path)?;

        let entry = match (old, new) {
            (None, None) => continue,
            (None, Some(new)) => FileChange {
                path,
                status: FileStatus::Added,
                base: None,
                hunks: vec![Hunk {
                    old_start: 1,
                    old_lines: 0,
                    new_start: 1,
                    new_lines: new.len() as u32,
                    lines: new.iter().map(|l| format!("+{l}")).collect(),
                    description: None,
                }],
            },
            (Some(old), None) => FileChange {
                path,
                status: FileStatus::Deleted,
                base: Some(old.clone()),
                hunks: vec![Hunk {
                    old_start: 1,
                    old_lines: old.len() as u32,
                    new_start: 1,
                    new_lines: 0,
                    lines: old.iter().map(|l| format!("-{l}")).collect(),
                    description: None,
                }],
            },
            (Some(old), Some(new)) => {
                let hunks = hunks_from(&old, &new);
                if hunks.is_empty() {
                    continue;
                }
                FileChange {
                    path,
                    status: FileStatus::Modified,
                    base: Some(old),
                    hunks,
                }
            }
        };
        files.push(entry);
    }

    Ok(Proposal { title: None, files })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_lines_drops_the_trailing_empty_line() {
        assert_eq!(to_lines("a\nb\n"), vec!["a", "b"]);
        assert_eq!(to_lines("a\nb"), vec!["a", "b"]);
        assert!(to_lines("").is_empty());
        // A file that is genuinely one empty line is one empty line.
        assert_eq!(to_lines("\n"), vec![""]);
    }

    #[test]
    fn diff_regions_reports_a_replacement() {
        let old: Vec<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        let new: Vec<String> = ["a", "B", "c"].iter().map(|s| s.to_string()).collect();
        assert_eq!(diff_regions(&old, &new), vec![(1, 2, 1, 2)]);
    }

    #[test]
    fn diff_regions_coalesces_adjacent_delete_and_insert() {
        // "b","c" replaced by "2","3" must be one region, not two.
        let old: Vec<String> = ["a", "b", "c", "d"].iter().map(|s| s.to_string()).collect();
        let new: Vec<String> = ["a", "2", "3", "d"].iter().map(|s| s.to_string()).collect();
        let regions = diff_regions(&old, &new);
        assert_eq!(regions.len(), 1, "got {regions:?}");
    }

    #[test]
    fn diff_regions_keeps_separated_edits_apart() {
        let old: Vec<String> = (1..=10).map(|i| format!("l{i}")).collect();
        let mut new = old.clone();
        new[1] = "X".to_string();
        new[8] = "Y".to_string();
        let regions = diff_regions(&old, &new);
        assert_eq!(regions.len(), 2, "got {regions:?}");
    }

    #[test]
    fn an_empty_to_empty_diff_has_no_regions() {
        assert!(diff_regions(&[], &[]).is_empty());
    }

    #[test]
    fn a_pure_insertion_before_the_first_line_is_old_start_one() {
        let old: Vec<String> = ["a"].iter().map(|s| s.to_string()).collect();
        let new: Vec<String> = ["new", "a"].iter().map(|s| s.to_string()).collect();
        let hunks = hunks_from(&old, &new);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].old_start, 1);
        assert_eq!(hunks[0].old_lines, 0);
        assert_eq!(hunks[0].lines, vec!["+new"]);
    }

    #[test]
    fn an_empty_file_to_content_is_one_insertion() {
        let new: Vec<String> = ["a", "b"].iter().map(|s| s.to_string()).collect();
        let hunks = hunks_from(&[], &new);
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].old_lines, 0);
        assert_eq!(hunks[0].new_lines, 2);
    }
}
