//! Typed request/reply shapes for the CodeForge wire API.
//!
//! Mirrors `codeforge-nvim/lua/codeforge/protocol.lua`: operations are
//! `info`, `list`, `status`, and `publish`. Adding a field the server does not
//! allow is an `invalid_request`, so these types stay deliberately close to the
//! server's allowlists.

use serde::{Deserialize, Serialize};

///A request frame. `#[serde(tag = "op")]` produces the server's flat shape,
///where the operation name and its fields sit in one object.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Request {
    Info,
    List {
        #[serde(skip_serializing_if = "Option::is_none")]
        limit: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cursor: Option<String>,
    },
    Status {
        id: String,
    },
    Publish {
        proposal: Proposal,
    },
}

///A change set to publish. Field names match the receiver's allowlists.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Proposal {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub files: Vec<FileChange>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileChange {
    pub path: String,
    pub status: FileStatus,
    ///Base content (O) the hunks were computed against. Omitted for `added`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base: Option<Vec<String>>,
    pub hunks: Vec<Hunk>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FileStatus {
    Added,
    Modified,
    Deleted,
}

///A single changed region.
///
///`old_start` is a 1-indexed *base* line number, so a pure insertion before
///base line N is `old_start = N, old_lines = 0`. This is deliberately not
///git's `@@ -N,0` header form, which means "after line N".
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Hunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    ///Diff lines, each prefixed with `+` or `-`.
    pub lines: Vec<String>,
    ///Optional single-row sidebar label; rejected if it carries control
    ///characters or exceeds 4096 bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

///The server's error object.
#[derive(Debug, Clone, Deserialize)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}

///Parse a reply frame, surfacing a protocol error as a Rust error.
///
///The envelope is inspected as a `Value` first because `ok` decides whether
///`result` or `error` is the meaningful half; deriving a generic envelope would
///also impose a `Deserialize` bound on the caller's type that is not needed here.
pub fn parse_reply<T: for<'de> Deserialize<'de>>(frame: &[u8]) -> Result<T, WireError> {
    let value: serde_json::Value =
        serde_json::from_slice(frame).map_err(|e| WireError::Malformed {
            message: e.to_string(),
        })?;
    let ok = value
        .get("ok")
        .and_then(|v| v.as_bool())
        .ok_or_else(|| WireError::Malformed {
            message: "reply has no boolean `ok` field".to_string(),
        })?;
    if ok {
        let result = value.get("result").ok_or(WireError::Malformed {
            message: "reply was ok but carried no result".to_string(),
        })?;
        serde_json::from_value(result.clone()).map_err(|e| WireError::Malformed {
            message: format!("result did not match the expected shape: {e}"),
        })
    } else {
        let err = value
            .get("error")
            .and_then(|e| serde_json::from_value::<ApiError>(e.clone()).ok())
            .unwrap_or(ApiError {
                code: "unknown".to_string(),
                message: "server reported failure without an error object".to_string(),
            });
        Err(WireError::Api {
            code: err.code,
            message: err.message,
        })
    }
}

///Errors decoding a reply or reporting a server-side failure.
#[derive(Debug)]
pub enum WireError {
    ///The frame was not a valid reply envelope.
    Malformed { message: String },
    ///The server refused the request (`ok: false`).
    Api { code: String, message: String },
}

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WireError::Malformed { message } => write!(f, "malformed reply: {message}"),
            WireError::Api { code, message } => write!(f, "server error ({code}): {message}"),
        }
    }
}

impl std::error::Error for WireError {}

///Result of `info`: where to publish and what is already tracked.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Info {
    ///The receiver's resolved working directory; publish paths resolve here.
    pub cwd: String,
    pub socket: String,
    pub changes: u32,
}

///Receipt for a published change set.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct PublishReceipt {
    pub id: String,
    pub files: Vec<PublishedFile>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct PublishedFile {
    pub path: String,
    pub hunks: Vec<PublishedHunk>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct PublishedHunk {
    pub id: String,
}

///Point-in-time review outcome for one change.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Status {
    pub id: String,
    pub status: ChangeStatus,
    pub under_review: bool,
    pub files: Vec<FileOutcome>,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ChangeStatus {
    Pending,
    Accepted,
    Rejected,
    Modified,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct FileOutcome {
    pub path: String,
    ///Diff type: `modified`, `added`, or `deleted`.
    pub status: FileStatus,
    ///File-level hand-edit flag, present for modified files.
    #[serde(default)]
    pub modified: Option<bool>,
    ///Per-hunk outcomes, present for modified files.
    #[serde(default)]
    pub hunks: Option<Vec<HunkOutcome>>,
    ///Whole-file decision, present for added/deleted files.
    #[serde(default)]
    pub decision: Option<ChangeStatus>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct HunkOutcome {
    pub id: String,
    pub status: HunkStatus,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HunkStatus {
    Pending,
    Conflicted,
    Accepted,
    Rejected,
}

///One page of `list`.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ChangeList {
    pub changes: Vec<ChangeSummary>,
    ///Total known changes, not the remaining pages.
    pub total: u32,
    pub has_more: bool,
    #[serde(default)]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct ChangeSummary {
    pub id: String,
    pub title: String,
    pub timestamp: i64,
    pub status: ChangeStatus,
    #[serde(default)]
    pub under_review: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn info_serializes_to_the_flat_operation_shape() {
        let json = serde_json::to_string(&Request::Info).unwrap();
        assert_eq!(json, r#"{"op":"info"}"#);
    }

    #[test]
    fn publish_omits_absent_optional_fields() {
        // The server rejects unknown fields, and `base` is invalid for an added
        // file, so absent options must not serialize as null.
        let req = Request::Publish {
            proposal: Proposal {
                title: None,
                files: vec![FileChange {
                    path: "a.lua".to_string(),
                    status: FileStatus::Added,
                    base: None,
                    hunks: vec![Hunk {
                        old_start: 1,
                        old_lines: 0,
                        new_start: 1,
                        new_lines: 1,
                        lines: vec!["+x".to_string()],
                        description: None,
                    }],
                }],
            },
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(!json.contains("null"), "unexpected null in {json}");
        assert!(json.contains(r#""op":"publish""#));
        assert!(json.contains(r#""status":"added""#));
    }

    #[test]
    fn a_protocol_error_becomes_an_api_error() {
        let frame = br#"{"ok":false,"error":{"code":"invalid_proposal","message":"bad"}}"#;
        let err = parse_reply::<Info>(frame).unwrap_err();
        match err {
            WireError::Api { code, message } => {
                assert_eq!(code, "invalid_proposal");
                assert_eq!(message, "bad");
            }
            other => panic!("expected Api, got {other:?}"),
        }
    }

    #[test]
    fn a_result_reply_parses() {
        let frame = br#"{"ok":true,"result":{"cwd":"/p","socket":"/s.sock","changes":3}}"#;
        let info: Info = parse_reply(frame).unwrap();
        assert_eq!(info.changes, 3);
        assert_eq!(info.cwd, "/p");
    }

    #[test]
    fn an_ok_reply_without_a_result_is_malformed() {
        let err = parse_reply::<Info>(br#"{"ok":true}"#).unwrap_err();
        assert!(matches!(err, WireError::Malformed { .. }), "got {err:?}");
    }

    #[test]
    fn a_non_reply_frame_is_malformed_not_a_panic() {
        let err = parse_reply::<Info>(br#"not json"#).unwrap_err();
        assert!(matches!(err, WireError::Malformed { .. }), "got {err:?}");
    }

    #[test]
    fn list_cursor_round_trips_and_reports_absence() {
        let page: ChangeList = parse_reply(
            br#"{"ok":true,"result":{"changes":[],"total":25,"has_more":true,"next_cursor":"v1:1758680000:cf-x-3"}}"#,
        )
        .unwrap();
        assert!(page.has_more);
        assert_eq!(page.next_cursor.as_deref(), Some("v1:1758680000:cf-x-3"));
        assert_eq!(page.total, 25);

        let last: ChangeList = parse_reply(
            br#"{"ok":true,"result":{"changes":[],"total":1,"has_more":false,"next_cursor":null}}"#,
        )
        .unwrap();
        assert_eq!(last.next_cursor, None);
    }
}
