//! `codeforge` — publish change sets to a running CodeForge editor and read
//! review outcomes back.
//!
//! The editor owns all review state; this binary is a client of its wire API.
//! Exit codes are meaningful so an agent loop can branch without parsing text:
//!
//! * `0` — success
//! * `1` — the request failed (server error, refused proposal, transport error)
//! * `2` — usage error
//! * `3` — the change is still awaiting review (`status --wait` timed out)

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use codeforge_agent::discovery;
use codeforge_agent::jj::{self, BuildOptions};
use codeforge_agent::socket;
use codeforge_agent::wire::{self, ChangeList, Info, PublishReceipt, Request, Status};

const EXIT_OK: u8 = 0;
const EXIT_FAILURE: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_PENDING: u8 = 3;

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        usage();
        return ExitCode::from(EXIT_USAGE);
    }
    let command = args.remove(0);
    let result = match command.as_str() {
        "info" => cmd_info(&args),
        "status" => cmd_status(&args),
        "list" => cmd_list(&args),
        "publish" => cmd_publish(&args),
        "-h" | "--help" | "help" => {
            usage();
            Ok(EXIT_OK)
        }
        other => {
            eprintln!("codeforge: unknown command {other:?}");
            usage();
            return ExitCode::from(EXIT_USAGE);
        }
    };
    match result {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("codeforge: {message}");
            ExitCode::from(EXIT_FAILURE)
        }
    }
}

///Number of files in a publish request, for reporting.
fn request_files(request: &Request) -> usize {
    match request {
        Request::Publish { proposal } => proposal.files.len(),
        _ => 0,
    }
}

fn usage() {
    eprintln!(
        "\
codeforge — publish change sets to a CodeForge editor and read outcomes

Usage:
  codeforge info [--socket PATH]
  codeforge status --id ID [--wait] [--timeout SECS] [--socket PATH]
  codeforge list [--limit N] [--cursor C] [--socket PATH]
  codeforge publish --repo PATH --from REV --to REV [--path PREFIX]
                    [--title TITLE] [--socket PATH] [--dry-run]

Socket resolution: --socket, then $CODEFORGE_SOCKET, then the platform default.

Exit codes: 0 ok, 1 failure, 2 usage, 3 still awaiting review (status --wait)."
    );
}

///Minimal flag parser: `--key value`, with bare `--flag` booleans.
struct Flags {
    values: std::collections::HashMap<String, String>,
    bools: std::collections::HashSet<String>,
}

impl Flags {
    fn parse(args: &[String], bool_flags: &[&str]) -> Result<Self, String> {
        let mut values = std::collections::HashMap::new();
        let mut bools = std::collections::HashSet::new();
        let mut i = 0;
        while i < args.len() {
            let arg = &args[i];
            let Some(name) = arg.strip_prefix("--") else {
                return Err(format!("unexpected argument {arg:?}"));
            };
            if bool_flags.contains(&name) {
                bools.insert(name.to_string());
                i += 1;
                continue;
            }
            let value = args
                .get(i + 1)
                .ok_or_else(|| format!("--{name} needs a value"))?;
            values.insert(name.to_string(), value.clone());
            i += 2;
        }
        Ok(Flags { values, bools })
    }

    fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(|s| s.as_str())
    }

    fn required(&self, name: &str) -> Result<&str, String> {
        self.get(name)
            .ok_or_else(|| format!("--{name} is required"))
    }

    fn has(&self, name: &str) -> bool {
        self.bools.contains(name) || self.values.contains_key(name)
    }

    fn socket(&self) -> PathBuf {
        discovery::resolve(self.get("socket").map(std::path::Path::new))
    }
}

///Send one request, returning the raw reply frame.
fn call(sock: &std::path::Path, request: &Request) -> Result<Vec<u8>, String> {
    let body = serde_json::to_vec(request).map_err(|e| format!("cannot encode request: {e}"))?;
    call_raw(sock, &body)
}

///Send an already-encoded frame, so what is shown in a dry run is byte-for-byte
///what a real publish transmits.
fn call_raw(sock: &std::path::Path, body: &[u8]) -> Result<Vec<u8>, String> {
    socket::request(sock, body, Duration::from_secs(30)).map_err(|e| e.to_string())
}

fn parse<T: for<'de> serde::Deserialize<'de>>(frame: &[u8]) -> Result<T, String> {
    wire::parse_reply(frame).map_err(|e| e.to_string())
}

fn cmd_info(args: &[String]) -> Result<u8, String> {
    let flags = Flags::parse(args, &[])?;
    let sock = flags.socket();
    let info: Info = parse(&call(&sock, &Request::Info)?)?;
    println!("cwd:     {}", info.cwd);
    println!("socket:  {}", info.socket);
    println!("changes: {}", info.changes);
    Ok(EXIT_OK)
}

fn cmd_list(args: &[String]) -> Result<u8, String> {
    let flags = Flags::parse(args, &[])?;
    let sock = flags.socket();
    let limit = match flags.get("limit") {
        Some(v) => Some(
            v.parse::<u32>()
                .map_err(|_| format!("--limit must be an integer, got {v:?}"))?,
        ),
        None => None,
    };
    let page: ChangeList = parse(&call(
        &sock,
        &Request::List {
            limit,
            cursor: flags.get("cursor").map(|s| s.to_string()),
        },
    )?)?;
    for c in &page.changes {
        println!(
            "{}  {:<9} {}",
            c.id,
            format!("{:?}", c.status).to_lowercase(),
            c.title
        );
    }
    if page.has_more {
        eprintln!(
            "({} of {} shown; continue with --cursor {})",
            page.changes.len(),
            page.total,
            page.next_cursor.as_deref().unwrap_or("")
        );
    }
    Ok(EXIT_OK)
}

fn cmd_status(args: &[String]) -> Result<u8, String> {
    let flags = Flags::parse(args, &["wait"])?;
    let sock = flags.socket();
    let id = flags.required("id")?.to_string();
    let timeout = match flags.get("timeout") {
        Some(v) => Duration::from_secs(
            v.parse::<u64>()
                .map_err(|_| format!("--timeout must be seconds, got {v:?}"))?,
        ),
        None => Duration::from_secs(600),
    };
    let wait = flags.has("wait");

    let deadline = Instant::now() + timeout;
    loop {
        let status: Status = parse(&call(&sock, &Request::Status { id: id.clone() })?)?;
        if !wait || !under_review(&status) {
            print_status(&status);
            return Ok(if wait && under_review(&status) {
                EXIT_PENDING
            } else {
                EXIT_OK
            });
        }
        if Instant::now() >= deadline {
            print_status(&status);
            eprintln!("codeforge: still awaiting review after {timeout:?}");
            return Ok(EXIT_PENDING);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

///`under_review` is the authoritative "not finished" signal: a change can have
///every hunk triaged while final assembly still blocks completion.
fn under_review(status: &Status) -> bool {
    status.under_review
}

fn print_status(status: &Status) {
    println!(
        "{}  {}  under_review={}",
        status.id,
        format!("{:?}", status.status).to_lowercase(),
        status.under_review
    );
    for f in &status.files {
        let detail = if let Some(hunks) = &f.hunks {
            hunks
                .iter()
                .map(|h| format!("{:?}", h.status).to_lowercase())
                .collect::<Vec<_>>()
                .join(", ")
        } else if let Some(decision) = f.decision {
            format!("{:?}", decision).to_lowercase()
        } else {
            String::new()
        };
        let edited = if f.modified == Some(true) {
            " edited"
        } else {
            ""
        };
        println!(
            "  {:<40} {:<9}{} {}",
            f.path,
            format!("{:?}", f.status).to_lowercase(),
            edited,
            detail
        );
    }
}

fn cmd_publish(args: &[String]) -> Result<u8, String> {
    let flags = Flags::parse(args, &["dry-run"])?;
    let sock = flags.socket();
    let opts = BuildOptions {
        repo: PathBuf::from(flags.required("repo")?),
        from: flags.required("from")?.to_string(),
        to: flags.required("to")?.to_string(),
        path_filter: flags.get("path").map(|s| s.to_string()),
    };

    let mut proposal = jj::build_proposal(&opts).map_err(|e| e.to_string())?;
    proposal.title = flags
        .get("title")
        .map(|s| s.to_string())
        .or(Some(format!("{} → {}", opts.from, opts.to)));
    if proposal.files.is_empty() {
        return Err(format!(
            "no changed files between {} and {} (path filter {:?})",
            opts.from, opts.to, opts.path_filter
        ));
    }

    let hunks: usize = proposal.files.iter().map(|f| f.hunks.len()).sum();
    let request = Request::Publish { proposal };
    let body = serde_json::to_vec(&request).map_err(|e| format!("cannot encode request: {e}"))?;

    if flags.has("dry-run") {
        // Report what *would* be sent, and check the size cap locally, so a
        // mistake surfaces before the editor sees anything. The byte count is
        // re-checked here because `call_raw` is where the cap is enforced.
        let files = request_files(&request);
        eprintln!(
            "dry run: {} file(s), {} hunk(s), {} bytes (cap {})",
            files,
            hunks,
            body.len(),
            socket::MAX_MESSAGE_BYTES
        );
        if body.len() > socket::MAX_MESSAGE_BYTES {
            return Err(format!(
                "proposal is {} bytes, over the {}-byte frame limit",
                body.len(),
                socket::MAX_MESSAGE_BYTES
            ));
        }
        eprintln!("dry run: nothing sent");
        return Ok(EXIT_OK);
    }

    let receipt: PublishReceipt = parse(&call_raw(&sock, &body)?)?;
    println!("{}", receipt.id);
    eprintln!(
        "published {} file(s), {} hunk(s)",
        receipt.files.len(),
        receipt.files.iter().map(|f| f.hunks.len()).sum::<usize>()
    );
    Ok(EXIT_OK)
}
