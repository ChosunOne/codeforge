//! Bounded, one-request-per-connection client for the CodeForge JSON socket.
//!
//! Framing mirrors the server exactly
//! (`codeforge-nvim/lua/codeforge/socket.lua`): one newline-terminated JSON
//! object per connection, one newline-terminated reply, then the server closes.
//!
//! The size cap is applied **before** connecting. The server aborts a
//! connection whose frame exceeds its own limit, so a client that wrote first
//! and asked later would surface a bare EOF instead of an actionable error.

use std::fmt;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

///Maximum content bytes per frame, excluding the terminating newline.
///
///Matches the server's `max_message_bytes` default
///(`lua/codeforge/socket.lua`). The frame terminator is not counted: the
///server measures the content before the newline.
pub const MAX_MESSAGE_BYTES: usize = 1024 * 1024;

///Errors from a socket request.
#[derive(Debug)]
pub enum SocketError {
    ///The request exceeded [`MAX_MESSAGE_BYTES`]; nothing was sent.
    TooLarge { limit: usize },
    ///Could not connect to the socket.
    Connect {
        path: String,
        source: std::io::Error,
    },
    ///I/O failed while reading the reply.
    Io(std::io::Error),
    ///The server closed without sending a complete frame.
    Truncated,
    ///The server did not reply within the deadline.
    Timeout,
}

impl fmt::Display for SocketError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SocketError::TooLarge { limit } => write!(
                f,
                "request exceeds the {limit}-byte frame limit; reduce the change set"
            ),
            SocketError::Connect { path, source } => {
                write!(f, "cannot connect to {path}: {source}")
            }
            SocketError::Io(e) => write!(f, "socket I/O failed: {e}"),
            SocketError::Truncated => {
                write!(f, "the server closed without sending a complete reply")
            }
            SocketError::Timeout => write!(f, "the server did not reply in time"),
        }
    }
}

impl std::error::Error for SocketError {}

impl From<std::io::Error> for SocketError {
    fn from(e: std::io::Error) -> Self {
        SocketError::Io(e)
    }
}

///Content length of a frame carrying `body`, or `None` when oversized.
///
///The newline is deliberately excluded, so a body of exactly the limit is
///accepted.
pub fn frame_len(body_len: usize) -> Option<usize> {
    if body_len > MAX_MESSAGE_BYTES {
        None
    } else {
        Some(body_len)
    }
}

///Send one request frame and return the reply frame (without its newline).
///
///Blocks until the reply is complete, the connection closes, or `timeout`
///elapses. The reply is returned as raw bytes: judging success is the caller's
///job, since a protocol-level error is still a well-formed reply.
pub fn request(path: &Path, body: &[u8], timeout: Duration) -> Result<Vec<u8>, SocketError> {
    if frame_len(body.len()).is_none() {
        return Err(SocketError::TooLarge {
            limit: MAX_MESSAGE_BYTES,
        });
    }

    let mut stream = UnixStream::connect(path).map_err(|e| SocketError::Connect {
        path: path.display().to_string(),
        source: e,
    })?;
    // A read timeout in addition to the overall budget, so a peer that dribbles
    // bytes forever cannot pin us past the deadline.
    stream
        .set_read_timeout(Some(timeout))
        .map_err(SocketError::Io)?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(SocketError::Io)?;

    let mut frame = Vec::with_capacity(body.len() + 1);
    frame.extend_from_slice(body);
    frame.push(b'\n');
    stream.write_all(&frame).map_err(SocketError::Io)?;
    stream.flush().map_err(SocketError::Io)?;

    let deadline = std::time::Instant::now() + timeout;
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 8192];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => {
                // EOF: complete only if a newline already terminated the frame.
                return match buf.iter().position(|&b| b == b'\n') {
                    Some(nl) => Ok(buf[..nl].to_vec()),
                    None => Err(SocketError::Truncated),
                };
            }
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if let Some(nl) = buf.iter().position(|&b| b == b'\n') {
                    // Anything after the first newline belongs to no frame of
                    // this protocol; ignore it rather than corrupting the reply.
                    return Ok(buf[..nl].to_vec());
                }
                if buf.len() > MAX_MESSAGE_BYTES {
                    return Err(SocketError::TooLarge {
                        limit: MAX_MESSAGE_BYTES,
                    });
                }
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut => {
                return Err(SocketError::Timeout);
            }
            Err(e) => return Err(SocketError::Io(e)),
        }
        if std::time::Instant::now() >= deadline {
            return Err(SocketError::Timeout);
        }
    }
}
