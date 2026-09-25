//! Client library for the CodeForge wire API.
//!
//! CodeForge's socket is a data-only, one-request-per-connection JSON protocol
//! hosted by a running Neovim instance (see `codeforge-nvim/lua/codeforge/`).
//! This crate is a *client* of that protocol, not a second store of record:
//! the editor owns all review state, and the only durable outcome record is its
//! decision log.

pub mod discovery;
pub mod jj;
pub mod socket;
pub mod wire;
