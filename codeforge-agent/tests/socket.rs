//! Adversarial tests for the one-request-per-connection socket client.
//!
//! These run against a real `UnixListener` mock rather than a trait double, so
//! they exercise the actual framing (partial reads, EOF, timeouts) that the
//! Neovim server produces. A stub would let us "pass" while still breaking on a
//! reply that arrives in two chunks.
//!
//! The mock uses a **non-blocking** accept loop with an atomic connection
//! counter. A blocking `accept()` would hang the test runner in exactly the
//! cases that matter most: when the client is supposed to refuse a request
//! without ever connecting, `accept()` never returns and a `join()` deadlocks.

#![cfg(unix)]

use std::io::{ErrorKind, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use codeforge_agent::socket::{self, SocketError};

static COUNTER: AtomicU32 = AtomicU32::new(0);

///A unique socket path; removed on drop so a panicking test cannot leak it.
struct TempSock(PathBuf);

impl TempSock {
    fn new() -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!(
            "codeforge-agent-test-{}-{}.sock",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_file(&path);
        TempSock(path)
    }
    fn path(&self) -> &PathBuf {
        &self.0
    }
}

impl Drop for TempSock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

///How the mock should answer a connection.
enum Behaviour {
    ///Write these bytes, then close.
    Reply(Vec<u8>),
    ///Write these bytes in chunks with a delay, then close.
    Chunked(Vec<Vec<u8>>),
    ///Read the request (counting its bytes), then close without replying.
    Silent,
    ///Write one byte every `interval`, never a newline. Defeats a per-read
    ///timeout on its own, so only an overall deadline can stop it.
    Dribble { interval: Duration },
}

///A non-blocking mock server; always bounded in lifetime.
struct MockServer {
    stop: Arc<AtomicBool>,
    connections: Arc<AtomicUsize>,
    received: Arc<AtomicUsize>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl MockServer {
    fn start(path: PathBuf, behaviour: Behaviour) -> Self {
        let listener = UnixListener::bind(&path).expect("bind mock listener");
        listener
            .set_nonblocking(true)
            .expect("mock listener must be non-blocking");
        let stop = Arc::new(AtomicBool::new(false));
        let connections = Arc::new(AtomicUsize::new(0));
        let received = Arc::new(AtomicUsize::new(0));

        let handle = std::thread::spawn({
            let stop = Arc::clone(&stop);
            let connections = Arc::clone(&connections);
            let received = Arc::clone(&received);
            move || {
                while !stop.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            connections.fetch_add(1, Ordering::SeqCst);
                            stream
                                .set_read_timeout(Some(Duration::from_secs(5)))
                                .expect("set read timeout");
                            received.fetch_add(drain(&mut stream), Ordering::SeqCst);
                            match &behaviour {
                                Behaviour::Reply(bytes) => {
                                    let _ = stream.write_all(bytes);
                                }
                                Behaviour::Chunked(chunks) => {
                                    for chunk in chunks {
                                        let _ = stream.write_all(chunk);
                                        let _ = stream.flush();
                                        std::thread::sleep(Duration::from_millis(20));
                                    }
                                }
                                Behaviour::Silent => {
                                    std::thread::sleep(Duration::from_millis(300));
                                }
                                Behaviour::Dribble { interval } => {
                                    // Stop as soon as the client hangs up, so a
                                    // fast client cannot leave this spinning.
                                    for _ in 0..1000 {
                                        if stream.write_all(b"x").is_err() {
                                            break;
                                        }
                                        let _ = stream.flush();
                                        std::thread::sleep(*interval);
                                    }
                                }
                            }
                            let _ = stream.flush();
                            drop(stream);
                        }
                        Err(e) if e.kind() == ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(5));
                        }
                        Err(_) => break,
                    }
                }
            }
        });

        MockServer {
            stop,
            connections,
            received,
            handle: Some(handle),
        }
    }

    fn connections(&self) -> usize {
        self.connections.load(Ordering::SeqCst)
    }

    fn bytes_received(&self) -> usize {
        self.received.load(Ordering::SeqCst)
    }
}

impl Drop for MockServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

///Read until the request frame's newline or EOF; returns bytes consumed.
fn drain(stream: &mut UnixStream) -> usize {
    let mut total = 0usize;
    let mut buf = [0u8; 65536];
    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                total += n;
                if buf[..n].contains(&b'\n') {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    total
}

fn request(path: &std::path::Path, body: &[u8]) -> Result<Vec<u8>, SocketError> {
    socket::request(path, body, Duration::from_secs(5))
}

fn framed(mut body: Vec<u8>) -> Vec<u8> {
    body.push(b'\n');
    body
}

#[test]
fn returns_the_reply_frame_without_the_trailing_newline() {
    let sock = TempSock::new();
    let server = MockServer::start(
        sock.path().clone(),
        Behaviour::Reply(framed(br#"{"ok":true,"result":{"changes":2}}"#.to_vec())),
    );

    let got = request(sock.path(), br#"{"op":"info"}"#).expect("request should succeed");
    assert_eq!(got, br#"{"ok":true,"result":{"changes":2}}"#);
    assert_eq!(server.connections(), 1);
}

#[test]
fn reassembles_a_reply_delivered_in_several_chunks() {
    // A reply that arrives in fragments is the common case on a socket, not an
    // edge case: reading once and parsing would fail intermittently.
    let sock = TempSock::new();
    let _server = MockServer::start(
        sock.path().clone(),
        Behaviour::Chunked(vec![
            b"{\"ok\":true,".to_vec(),
            b"\"result\":{\"a\":1}".to_vec(),
            b"}\n".to_vec(),
        ]),
    );

    let got = request(sock.path(), br#"{"op":"info"}"#).expect("request should succeed");
    assert_eq!(got, br#"{"ok":true,"result":{"a":1}}"#);
}

#[test]
fn ignores_data_after_the_first_newline() {
    // The protocol is one frame per connection; anything after the newline is
    // not part of this reply and must not be concatenated into it.
    let sock = TempSock::new();
    let _server = MockServer::start(
        sock.path().clone(),
        Behaviour::Reply(b"{\"ok\":true}\nGARBAGE\n".to_vec()),
    );

    let got = request(sock.path(), br#"{"op":"info"}"#).expect("request should succeed");
    assert_eq!(got, br#"{"ok":true}"#);
}

#[test]
fn an_oversized_request_is_refused_before_connecting() {
    // The server drops a connection whose frame exceeds its cap, so a client
    // that sends first and asks later would see a confusing EOF instead of a
    // clear error. The mock server must never be contacted at all.
    let sock = TempSock::new();
    let server = MockServer::start(
        sock.path().clone(),
        Behaviour::Reply(framed(b"{\"ok\":true}".to_vec())),
    );

    let body = vec![b'x'; socket::MAX_MESSAGE_BYTES + 1];
    let err = request(sock.path(), &body).expect_err("oversized request must be refused");
    match err {
        SocketError::TooLarge { limit } => assert_eq!(limit, socket::MAX_MESSAGE_BYTES),
        other => panic!("expected TooLarge, got {other:?}"),
    }
    assert_eq!(
        server.connections(),
        0,
        "server must not have been contacted"
    );
    assert_eq!(server.bytes_received(), 0);
}

#[test]
fn a_request_exactly_at_the_cap_is_sent_whole() {
    // Off-by-one the other way: the cap is inclusive and excludes the newline,
    // so a frame of exactly the limit must go through untouched.
    let sock = TempSock::new();
    let server = MockServer::start(
        sock.path().clone(),
        Behaviour::Reply(framed(b"{\"ok\":true}".to_vec())),
    );

    let body = vec![b'x'; socket::MAX_MESSAGE_BYTES];
    let got = request(sock.path(), &body).expect("at-cap request should succeed");
    assert_eq!(got, br#"{"ok":true}"#);
    assert_eq!(server.connections(), 1);
    assert_eq!(
        server.bytes_received(),
        socket::MAX_MESSAGE_BYTES + 1,
        "server should see the whole body plus its newline"
    );
}

#[test]
fn an_eof_without_a_newline_is_an_error_not_a_truncated_reply() {
    // A half-written reply must not be returned as if complete: the caller
    // would try to parse invalid JSON and report the wrong problem.
    let sock = TempSock::new();
    let _server = MockServer::start(
        sock.path().clone(),
        Behaviour::Reply(br#"{"ok":tr"#.to_vec()),
    );

    let err = request(sock.path(), br#"{"op":"info"}"#).expect_err("truncated reply must fail");
    match err {
        SocketError::Truncated => {}
        other => panic!("expected Truncated, got {other:?}"),
    }
}

#[test]
fn an_empty_reply_is_an_error() {
    let sock = TempSock::new();
    let _server = MockServer::start(sock.path().clone(), Behaviour::Reply(Vec::new()));

    let err = request(sock.path(), br#"{"op":"info"}"#).expect_err("empty reply must fail");
    assert!(matches!(err, SocketError::Truncated), "got {err:?}");
}

#[test]
fn a_server_that_never_replies_times_out() {
    // Without a deadline this hangs forever, which in an agent loop is worse
    // than an error.
    let sock = TempSock::new();
    let _server = MockServer::start(sock.path().clone(), Behaviour::Silent);

    let start = Instant::now();
    let err = socket::request(sock.path(), br#"{"op":"info"}"#, Duration::from_millis(150))
        .expect_err("a silent server must time out");
    let elapsed = start.elapsed();
    assert!(matches!(err, SocketError::Timeout), "got {err:?}");
    assert!(
        elapsed < Duration::from_millis(1500),
        "timed out too late: {elapsed:?}"
    );
}

#[test]
fn a_server_that_dribbles_bytes_without_a_newline_still_times_out() {
    // A slow drip defeats a per-read timeout: every individual read succeeds,
    // so only the overall deadline stops it. Without that deadline this loops
    // until the mock stops or memory grows, which is the failure mode most
    // likely to wedge an agent loop.
    let sock = TempSock::new();
    let _server = MockServer::start(
        sock.path().clone(),
        Behaviour::Dribble {
            interval: Duration::from_millis(10),
        },
    );

    let start = Instant::now();
    let err = socket::request(sock.path(), br#"{"op":"info"}"#, Duration::from_millis(200))
        .expect_err("a dribbling server must time out");
    let elapsed = start.elapsed();
    assert!(matches!(err, SocketError::Timeout), "got {err:?}");
    assert!(
        elapsed < Duration::from_millis(1500),
        "timed out too late: {elapsed:?}"
    );
}

#[test]
fn a_missing_socket_is_a_connection_error() {
    let sock = TempSock::new();
    let err = request(sock.path(), br#"{"op":"info"}"#).expect_err("missing socket must fail");
    match err {
        SocketError::Connect { .. } => {}
        other => panic!("expected Connect, got {other:?}"),
    }
}

#[test]
fn the_newline_is_not_counted_against_the_limit() {
    // The cap applies to the content before the newline (the server measures
    // exactly that), so a limit-sized body must not be rejected because of the
    // terminator we append.
    let limit = socket::MAX_MESSAGE_BYTES;
    assert_eq!(
        socket::frame_len(limit),
        Some(limit),
        "frame_len must measure content only"
    );
    assert_eq!(socket::frame_len(limit + 1), None);
    assert_eq!(socket::frame_len(0), Some(0));
}
