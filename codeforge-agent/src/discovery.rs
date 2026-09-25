//! Socket address resolution.
//!
//! CodeForge's default address is derived from the *editor's* runtime
//! directory, which is not necessarily this process's: the agent and the user
//! are frequently different Unix accounts with different `$XDG_RUNTIME_DIR`.
//! So an explicit `--socket` or `CODEFORGE_SOCKET` is the reliable path, and
//! the default is only a best-effort guess for the same-user case.

use std::path::{Path, PathBuf};

///Environment variable naming the socket explicitly.
pub const SOCKET_ENV: &str = "CODEFORGE_SOCKET";

///Resolve the socket address: explicit flag, then `CODEFORGE_SOCKET`, then the
///platform default for this user.
pub fn resolve(explicit: Option<&Path>) -> PathBuf {
    if let Some(path) = explicit {
        return path.to_path_buf();
    }
    if let Some(value) = std::env::var_os(SOCKET_ENV) {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    platform_default()
}

///The default address for this user, mirroring `transport.socket_path()` in
///`codeforge-nvim/lua/codeforge/transport.lua`.
///
///On Unix this is `$XDG_RUNTIME_DIR/codeforge.sock`, falling back to
///`/run/user/<uid>/codeforge.sock`. Windows named pipes are not modelled here.
pub fn platform_default() -> PathBuf {
    if let Some(run) = std::env::var_os("XDG_RUNTIME_DIR") {
        if !run.is_empty() {
            return PathBuf::from(run).join("codeforge.sock");
        }
    }
    // SAFETY: `geteuid` takes no arguments and cannot fail.
    let uid = unsafe { libc_geteuid() };
    PathBuf::from(format!("/run/user/{uid}/codeforge.sock"))
}

#[cfg(unix)]
unsafe fn libc_geteuid() -> u32 {
    extern "C" {
        fn geteuid() -> u32;
    }
    geteuid()
}

#[cfg(not(unix))]
unsafe fn libc_geteuid() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_explicit_path_wins_over_the_environment() {
        std::env::set_var(SOCKET_ENV, "/from/env.sock");
        let got = resolve(Some(Path::new("/explicit.sock")));
        std::env::remove_var(SOCKET_ENV);
        assert_eq!(got, PathBuf::from("/explicit.sock"));
    }

    #[test]
    fn the_environment_wins_over_the_default() {
        std::env::set_var(SOCKET_ENV, "/from/env.sock");
        let got = resolve(None);
        std::env::remove_var(SOCKET_ENV);
        assert_eq!(got, PathBuf::from("/from/env.sock"));
    }

    #[test]
    fn the_default_is_a_socket_path_outside_the_repo() {
        // Guard against an empty string sneaking through as a "default".
        let default = platform_default();
        assert!(default.to_string_lossy().ends_with(".sock"));
        assert!(default.is_absolute());
    }
}
