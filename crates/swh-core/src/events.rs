//! Outbound notifications from the core to the host that embeds it.
//!
//! The native app forwards them to Swift through a C callback. Names and
//! payloads match what upstream's Tauri app emits to its webview, in the same
//! `{ "_args": [...] }` envelope, so the renderer contract does not change.

use serde_json::Value;

/// Event name asking the host to refresh its tray title. The core cannot
/// draw the tray, so it asks instead of calling into the host.
pub const TRAY_TITLE_REFRESH: &str = "tray_title_refresh";

/// Receives events from the core. Implementations must be cheap and must
/// not block: the core calls `emit` while holding no locks, but the caller
/// may be on an async worker.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: &str, payload: Value);
}

/// Drops every event. For tests and for hosts that do not listen.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoopEvents;

impl EventSink for NoopEvents {
    fn emit(&self, _event: &str, _payload: Value) {}
}
