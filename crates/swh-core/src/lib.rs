//! Tauri-free SwitchHosts core.
//!
//! Everything here is plain Rust with no dependency on Tauri, so it can back
//! the native macOS app (through `crates/swh-ffi`). Window, tray, menu and
//! event wiring belong to the host, not to this crate.
//!
//! Upstream's Tauri-free modules are compiled in place from `src-tauri/src`:
//! the fork never edits them, and upstream fixes reach the native app with no
//! porting. The other modules are fork-owned rewrites of Tauri-coupled logic,
//! each tracked against its upstream source in `crates/upstream-sync.txt`.

// Mounted at the crate root under their upstream names, so upstream's
// `crate::storage::…` paths resolve unchanged and tests that re-run the test
// binary by exact path (`storage::transaction::tests::…`) still match.
#[path = "../../../src-tauri/src/dns.rs"]
pub mod dns;
#[path = "../../../src-tauri/src/helper_proto/mod.rs"]
pub mod helper_proto;
// Upstream keeps `ELEVATION_HELPER_ARG` for its own lib tests; nothing here
// reads it.
#[path = "../../../src-tauri/src/hosts_apply/mod.rs"]
#[cfg_attr(test, allow(dead_code))]
pub mod hosts_apply;
#[path = "../../../src-tauri/src/hosts_text.rs"]
pub mod hosts_text;
#[path = "../../../src-tauri/src/migration/mod.rs"]
pub mod migration;
#[path = "../../../src-tauri/src/storage/mod.rs"]
pub mod storage;

// `http.rs` and `import_export.rs` keep their children in a sibling directory,
// but rustc looks for the children of a `#[path]` file next to the file. A
// directory-level inline module loads them with upstream's own layout.
#[path = "../../../src-tauri/src"]
mod upstream {
    pub mod http;
    pub mod import_export;
}
pub use upstream::{http, import_export};

pub mod api;
pub mod apply;
mod bootstrap;
pub mod events;
#[cfg(test)]
mod extra_tests;
pub mod find;
pub mod http_api;
pub mod refresh;
pub mod toggle;
