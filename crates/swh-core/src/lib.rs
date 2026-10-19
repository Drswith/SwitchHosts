//! Tauri-free SwitchHosts core.
//!
//! Everything here is plain Rust with no dependency on Tauri, so the same
//! code can back the Tauri app and the native macOS app (through
//! `crates/swh-ffi`). Window, tray, menu and event wiring belong to the
//! hosts, not to this crate.

pub mod api;
pub mod apply;
pub mod dns;
pub mod events;
pub mod find;
pub mod helper_proto;
pub mod http_api;
pub mod hosts_apply;
pub mod hosts_text;
pub mod refresh;
pub mod http;
pub mod import_export;
pub mod migration;
pub mod storage;
pub mod toggle;
