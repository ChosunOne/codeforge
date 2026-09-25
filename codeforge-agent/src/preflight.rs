//! Local pre-flight: the checks a sender can make before touching the wire.
//!
//! These deliberately cover only what is knowable **without the receiver**:
//! path shape, containment against the `cwd` reported by `info`, hunk geometry,
//! and the frame budget. Anything that depends on the receiver's disk or its
//! tracked changes cannot be checked here and is left to the receiver, which
//! reports every refused path in one reply.
//!
//! The point is to catch a whole class of mistakes *before* a round trip, and to
//! say precisely what is wrong, rather than surfacing a bare transport error.

use std::path::{Component, Path};

use crate::wire::{FileChange, FileStatus, Proposal};

///A problem found locally. Every variant carries the offending path so a batch
///report can name each one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Problem {
    ///A path is not usable as a receiver-relative path.
    BadPath { path: String, reason: String },
    ///A path escapes the receiver's working directory.
    Outside { path: String, cwd: String },
    ///A `modified` file carries no base to merge against.
    MissingBase { path: String },
    ///An `added` file must not carry a base.
    UnexpectedBase { path: String },
    ///An `added` file must consist of exactly one insertion hunk.
    BadAddedFile { path: String, reason: String },
    ///A hunk's declared line counts disagree with its own lines.
    HunkMismatch {
        path: String,
        index: usize,
        detail: String,
    },
    ///Hunk base ranges overlap or share a start.
    OverlappingHunks {
        path: String,
        first: usize,
        second: usize,
    },
    ///The encoded request exceeds the frame budget.
    TooLarge { bytes: usize, limit: usize },
}

impl std::fmt::Display for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Problem::BadPath { path, reason } => write!(f, "path {path:?} {reason}"),
            Problem::Outside { path, cwd } => {
                write!(
                    f,
                    "path {path:?} is outside the receiver's working directory {cwd:?}"
                )
            }
            Problem::MissingBase { path } => {
                write!(
                    f,
                    "path {path:?}: a modified file needs the base it was diffed against"
                )
            }
            Problem::UnexpectedBase { path } => {
                write!(f, "path {path:?}: an added file must not carry a base")
            }
            Problem::BadAddedFile { path, reason } => {
                write!(f, "path {path:?}: {reason}")
            }
            Problem::HunkMismatch {
                path,
                index,
                detail,
            } => write!(f, "path {path:?}: hunk {index}: {detail}"),
            Problem::OverlappingHunks {
                path,
                first,
                second,
            } => write!(
                f,
                "path {path:?}: hunks {first} and {second} overlap or share a base start"
            ),
            Problem::TooLarge { bytes, limit } => write!(
                f,
                "the request is {bytes} bytes, over the {limit}-byte frame limit"
            ),
        }
    }
}

///Check a receiver-relative path's shape.
///
///The receiver also canonicalizes and containment-checks; this catches the
///obvious cases early and, importantly, catches the ones the receiver *cannot*
///see because it resolves them differently (a bare `..` inside the connected
///path, a NUL byte, an empty path).
fn check_path_shape(path: &str) -> Result<(), String> {
    if path.is_empty() {
        return Err("is empty".to_string());
    }
    if path.contains('\0') {
        return Err("contains a NUL byte".to_string());
    }
    if Path::new(path).is_absolute() {
        return Err(
            "is absolute; send a path relative to the receiver's working directory".to_string(),
        );
    }
    for component in Path::new(path).components() {
        match component {
            Component::ParentDir => {
                return Err("contains `..`; send a path inside the working directory".to_string());
            }
            Component::Prefix(_) | Component::RootDir => {
                return Err(
                    "is absolute; send a path relative to the receiver's working directory"
                        .to_string(),
                );
            }
            _ => {}
        }
    }
    Ok(())
}

///True when `path`, resolved lexically against `cwd`, stays inside `cwd`.
///
///Lexical only: this cannot follow symlinks (it has no access to the receiver's
///filesystem), so it is a fast pre-check, not a replacement for the receiver's
///canonical check. It exists because `..` is rejected by `check_path_shape`
///anyway, and this is the belt to that braces: the check tracks absolute depth
///rather than merely counting, so it cannot be fooled by a path that leaves and
///re-enters the tree.
fn within(cwd: &str, path: &str) -> bool {
    let cwd = cwd.trim_end_matches('/');
    let mut stack: Vec<String> = Vec::new();
    for component in Path::new(cwd).components() {
        match component {
            Component::Normal(s) => stack.push(s.to_string_lossy().into_owned()),
            Component::RootDir => stack.clear(),
            Component::Prefix(_) => return false,
            _ => {}
        }
    }
    let base_depth = stack.len();
    for component in Path::new(path).components() {
        match component {
            Component::Normal(s) => stack.push(s.to_string_lossy().into_owned()),
            Component::CurDir => {}
            Component::ParentDir => {
                // Ascending past the cwd is exactly the escape this rejects.
                if stack.len() <= base_depth {
                    return false;
                }
                stack.pop();
            }
            Component::RootDir | Component::Prefix(_) => return false,
        }
    }
    true
}

///Run every local check over `proposal`, encoded as `body`.
///
///Returns all problems found, in file order, so a caller can report a batch
///rather than one issue per attempt.
pub fn check(proposal: &Proposal, cwd: &str, body_bytes: usize, limit: usize) -> Vec<Problem> {
    let mut problems = Vec::new();

    for file in &proposal.files {
        let path = &file.path;
        if let Err(reason) = check_path_shape(path) {
            problems.push(Problem::BadPath {
                path: path.clone(),
                reason,
            });
            // A path we cannot even parse is not worth further inspection.
            continue;
        }
        if !within(cwd, path) {
            problems.push(Problem::Outside {
                path: path.clone(),
                cwd: cwd.to_string(),
            });
            continue;
        }
        check_file(file, &mut problems);
    }

    if body_bytes > limit {
        problems.push(Problem::TooLarge {
            bytes: body_bytes,
            limit,
        });
    }

    problems
}

fn check_file(file: &FileChange, problems: &mut Vec<Problem>) {
    let path = file.path.clone();
    match file.status {
        FileStatus::Modified => {
            if file.base.is_none() {
                problems.push(Problem::MissingBase { path });
                return;
            }
        }
        FileStatus::Added => {
            if file.base.is_some() {
                problems.push(Problem::UnexpectedBase { path });
                return;
            }
            if file.hunks.len() != 1 {
                problems.push(Problem::BadAddedFile {
                    path,
                    reason: format!(
                        "an added file takes exactly one hunk, got {}",
                        file.hunks.len()
                    ),
                });
                return;
            }
        }
        FileStatus::Deleted => {}
    }

    let base_len = file.base.as_ref().map(|b| b.len()).unwrap_or(0);
    for (i, hunk) in file.hunks.iter().enumerate() {
        let minus = hunk.lines.iter().filter(|l| l.starts_with('-')).count();
        let plus = hunk.lines.iter().filter(|l| l.starts_with('+')).count();
        if minus as u32 != hunk.old_lines {
            problems.push(Problem::HunkMismatch {
                path: path.clone(),
                index: i + 1,
                detail: format!("{} '-' lines but old_lines is {}", minus, hunk.old_lines),
            });
        }
        if plus as u32 != hunk.new_lines {
            problems.push(Problem::HunkMismatch {
                path: path.clone(),
                index: i + 1,
                detail: format!("{} '+' lines but new_lines is {}", plus, hunk.new_lines),
            });
        }
        if let Some(bad) = hunk.lines.iter().find(|l| {
            let first = l.chars().next();
            first != Some('+') && first != Some('-')
        }) {
            problems.push(Problem::HunkMismatch {
                path: path.clone(),
                index: i + 1,
                detail: format!("line {bad:?} has no +/- prefix"),
            });
        }

        // A modified file's removed lines must match the base they claim.
        if file.status == FileStatus::Modified {
            if let Some(base) = file.base.as_ref() {
                if hunk.old_start == 0 || (hunk.old_start + hunk.old_lines) as usize > base_len + 1
                {
                    problems.push(Problem::HunkMismatch {
                        path: path.clone(),
                        index: i + 1,
                        detail: format!(
                            "base range {}+{} extends past the end of base ({} lines)",
                            hunk.old_start, hunk.old_lines, base_len
                        ),
                    });
                } else {
                    // Each removed line must equal the base line it replaces;
                    // the receiver checks this, and a mismatch means the base
                    // is not the content the hunks were built from.
                    let mut row = (hunk.old_start - 1) as usize;
                    for line in &hunk.lines {
                        if let Some(rest) = line.strip_prefix('-') {
                            if base.get(row).map(String::as_str) != Some(rest) {
                                problems.push(Problem::HunkMismatch {
                                    path: path.clone(),
                                    index: i + 1,
                                    detail: format!(
                                        "removed line does not match base line {}",
                                        row + 1
                                    ),
                                });
                                break;
                            }
                            row += 1;
                        }
                    }
                }
            }
        }
    }

    // Overlapping or shared-start base ranges are refused by the receiver.
    let mut order: Vec<usize> = (0..file.hunks.len()).collect();
    order.sort_by_key(|&i| file.hunks[i].old_start);
    for pair in order.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        let (first, second) = (&file.hunks[a], &file.hunks[b]);
        if second.old_start < first.old_start + first.old_lines
            || second.old_start == first.old_start
        {
            problems.push(Problem::OverlappingHunks {
                path: path.clone(),
                first: a + 1,
                second: b + 1,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Hunk;

    fn hunk(old_start: u32, old_lines: u32, lines: &[&str]) -> Hunk {
        let minus = lines.iter().filter(|l| l.starts_with('-')).count() as u32;
        let plus = lines.iter().filter(|l| l.starts_with('+')).count() as u32;
        Hunk {
            old_start,
            old_lines,
            new_start: old_start,
            new_lines: if plus > 0 { plus } else { minus },
            lines: lines.iter().map(|s| s.to_string()).collect(),
            description: None,
        }
    }

    fn modified(path: &str, base: &[&str], hunks: Vec<Hunk>) -> FileChange {
        FileChange {
            path: path.to_string(),
            status: FileStatus::Modified,
            base: Some(base.iter().map(|s| s.to_string()).collect()),
            hunks,
        }
    }

    fn proposal(files: Vec<FileChange>) -> Proposal {
        Proposal { title: None, files }
    }

    #[test]
    fn a_clean_proposal_has_no_problems() {
        let p = proposal(vec![modified(
            "src/a.rs",
            &["x", "y"],
            vec![hunk(2, 1, &["-y", "+Y"])],
        )]);
        assert!(check(&p, "/repo", 100, 1024).is_empty());
    }

    #[test]
    fn an_outside_path_is_reported() {
        let p = proposal(vec![modified(
            "../evil.rs",
            &["x"],
            vec![hunk(1, 1, &["-x", "+y"])],
        )]);
        let got = check(&p, "/repo", 10, 1024);
        assert!(matches!(got[0], Problem::BadPath { .. }), "got {got:?}");
    }

    #[test]
    fn an_absolute_path_is_reported_as_absolute() {
        let p = proposal(vec![modified(
            "/etc/passwd",
            &["x"],
            vec![hunk(1, 1, &["-x", "+y"])],
        )]);
        let got = check(&p, "/repo", 10, 1024);
        match &got[0] {
            Problem::BadPath { reason, .. } => assert!(reason.contains("absolute"), "{reason}"),
            other => panic!("expected BadPath, got {other:?}"),
        }
    }

    #[test]
    fn a_path_escaping_through_nested_parents_is_reported() {
        let p = proposal(vec![modified(
            "a/../../out.rs",
            &["x"],
            vec![hunk(1, 1, &["-x", "+y"])],
        )]);
        let got = check(&p, "/repo", 10, 1024);
        assert!(!got.is_empty(), "must be refused");
    }

    #[test]
    fn a_sibling_sharing_a_prefix_is_inside_only_with_the_separator() {
        // "/repo-other/x.rs" must not read as inside "/repo".
        assert!(within("/repo", "a.rs"));
        assert!(within("/repo", "src/a.rs"));
        assert!(!within("/repo", "../repo-other/a.rs"));
    }

    #[test]
    fn hunk_line_counts_are_checked_against_the_lines() {
        let mut h = hunk(1, 1, &["-x", "+y"]);
        h.old_lines = 5; // lie
        let p = proposal(vec![modified("a.rs", &["x"], vec![h])]);
        let got = check(&p, "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::HunkMismatch { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn a_line_without_a_prefix_is_reported() {
        let mut h = hunk(1, 1, &["-x", "+y"]);
        h.lines.push("no prefix".to_string());
        let p = proposal(vec![modified("a.rs", &["x"], vec![h])]);
        let got = check(&p, "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::HunkMismatch { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn overlapping_hunks_are_reported() {
        let p = proposal(vec![modified(
            "a.rs",
            &["a", "b", "c", "d"],
            vec![
                hunk(1, 2, &["-a", "-b", "+A"]),
                hunk(2, 2, &["-b", "-c", "+B"]),
            ],
        )]);
        let got = check(&p, "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::OverlappingHunks { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn an_adjacent_hunk_that_does_not_overlap_is_accepted() {
        let p = proposal(vec![modified(
            "a.rs",
            &["a", "b", "c", "d"],
            vec![hunk(1, 1, &["-a", "+A"]), hunk(3, 1, &["-c", "+C"])],
        )]);
        assert!(check(&p, "/repo", 10, 1024).is_empty());
    }

    #[test]
    fn a_modified_file_without_a_base_is_reported() {
        let mut f = modified("a.rs", &["x"], vec![hunk(1, 1, &["-x", "+y"])]);
        f.base = None;
        let got = check(&proposal(vec![f]), "/repo", 10, 1024);
        assert!(
            got.iter().any(|p| matches!(p, Problem::MissingBase { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn an_added_file_with_a_base_or_several_hunks_is_reported() {
        let with_base = FileChange {
            path: "new.rs".to_string(),
            status: FileStatus::Added,
            base: Some(vec!["x".to_string()]),
            hunks: vec![hunk(1, 0, &["+a"])],
        };
        let got = check(&proposal(vec![with_base]), "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::UnexpectedBase { .. })),
            "got {got:?}"
        );

        let two_hunks = FileChange {
            path: "new.rs".to_string(),
            status: FileStatus::Added,
            base: None,
            hunks: vec![hunk(1, 0, &["+a"]), hunk(2, 0, &["+b"])],
        };
        let got = check(&proposal(vec![two_hunks]), "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::BadAddedFile { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn an_oversized_request_is_reported_last() {
        let p = proposal(vec![modified(
            "a.rs",
            &["x"],
            vec![hunk(1, 1, &["-x", "+y"])],
        )]);
        let got = check(&p, "/repo", 9999, 1024);
        assert!(
            matches!(got.last(), Some(Problem::TooLarge { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn a_removed_line_that_disagrees_with_the_base_is_reported() {
        // The receiver refuses this, and it means the base is not the content
        // the hunks were built from — exactly the mistake worth catching early.
        let bad = modified("a.rs", &["x", "y"], vec![hunk(1, 1, &["-WRONG", "+z"])]);
        let got = check(&proposal(vec![bad]), "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::HunkMismatch { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn a_hunk_base_range_past_the_end_is_reported() {
        let bad = modified("a.rs", &["x"], vec![hunk(1, 5, &["-x", "+z"])]);
        let got = check(&proposal(vec![bad]), "/repo", 10, 1024);
        assert!(
            got.iter()
                .any(|p| matches!(p, Problem::HunkMismatch { .. })),
            "got {got:?}"
        );
    }

    #[test]
    fn every_problem_names_its_path_so_a_batch_can_be_reported() {
        let p = proposal(vec![
            modified("one.rs", &["x"], vec![hunk(1, 1, &["-x", "+y"])]),
            modified("two.rs", &["y"], vec![hunk(1, 1, &["-y", "+z"])]),
        ]);
        let mut bad = p.clone();
        bad.files[0].hunks[0].old_lines = 9;
        bad.files[1].hunks[0].old_lines = 9;
        let got = check(&bad, "/repo", 10, 1024);
        let text = format!("{got:?}");
        assert!(
            text.contains("one.rs") && text.contains("two.rs"),
            "got {text}"
        );
    }
}
