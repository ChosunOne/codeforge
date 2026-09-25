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
    let from_env = std::env::var_os(SOCKET_ENV);
    let default = platform_default();
    choose(explicit, from_env.as_deref(), default)
}

///Precedence rule, separated from the environment lookup so it can be tested
///without mutating process-global state (concurrent tests share one process).
///
///An empty environment value is ignored rather than resolving to the empty
///path, which would otherwise look like a configured-but-broken socket.
fn choose(
    explicit: Option<&Path>,
    from_env: Option<&std::ffi::OsStr>,
    default: PathBuf,
) -> PathBuf {
    if let Some(path) = explicit {
        return path.to_path_buf();
    }
    if let Some(value) = from_env {
        if !value.is_empty() {
            return PathBuf::from(value);
        }
    }
    default
}

///The default address for this user, mirroring `transport.socket_path()` in
///`codeforge-nvim/lua/codeforge/transport.lua`.
///
///On Unix this is `$XDG_RUNTIME_DIR/codeforge.sock`, falling back to
///`/run/user/<uid>/codeforge.sock`. Windows named pipes are not modelled here.
pub fn platform_default() -> PathBuf {
    let run = std::env::var_os("XDG_RUNTIME_DIR");
    default_for(run.as_deref())
}

fn default_for(xdg_runtime_dir: Option<&std::ffi::OsStr>) -> PathBuf {
    if let Some(run) = xdg_runtime_dir {
        if !run.is_empty() {
            return PathBuf::from(run).join("codeforge.sock");
        }
    }
    // SAFETY: `geteuid` takes no arguments and cannot fail. A uid lookup is the
    // only non-pure input here, so it stays behind the wrapper.
    let uid = unsafe { libc_geteuid() };
    PathBuf::from(format!("/run/user/{uid}/codeforge.sock"))
}

#[cfg(unix)]
unsafe fn libc_geteuid() -> u32 {
    // `extern` blocks must be explicitly unsafe in recent toolchains.
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() }
}

#[cfg(not(unix))]
unsafe fn libc_geteuid() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;

    fn def() -> PathBuf {
        PathBuf::from("/def/codeforge.sock")
    }

    #[test]
    fn an_explicit_path_wins_over_the_environment() {
        let got = choose(
            Some(Path::new("/explicit.sock")),
            Some(OsStr::new("/from/env.sock")),
            def(),
        );
        assert_eq!(got, PathBuf::from("/explicit.sock"));
    }

    #[test]
    fn the_environment_wins_over_the_default() {
        let got = choose(None, Some(OsStr::new("/from/env.sock")), def());
        assert_eq!(got, PathBuf::from("/from/env.sock"));
    }

    #[test]
    fn an_empty_environment_value_falls_through_to_the_default() {
        // An empty CODEFORGE_SOCKET must not resolve to an empty path: it would
        // look configured while pointing nowhere.
        let got = choose(None, Some(OsStr::new("")), def());
        assert_eq!(got, def());
    }

    #[test]
    fn with_nothing_set_the_default_is_absolute_and_named_sock() {
        let got = choose(None, None, def());
        assert_eq!(got, def());
        assert!(platform_default().is_absolute());
        assert!(platform_default().to_string_lossy().ends_with(".sock"));
    }

    #[test]
    fn an_xdg_runtime_dir_is_used_when_present() {
        let got = default_for(Some(OsStr::new("/run/user/1234")));
        assert_eq!(got, PathBuf::from("/run/user/1234/codeforge.sock"));
    }

    #[test]
    fn an_empty_xdg_runtime_dir_falls_back_to_the_uid_path() {
        let got = default_for(Some(OsStr::new("")));
        assert!(got.to_string_lossy().starts_with("/run/user/"));
        assert!(got.to_string_lossy().ends_with("/codeforge.sock"));
    }
}
