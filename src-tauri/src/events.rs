//! Forwards core events to the Tauri webview and tray.
//!
//! The core only knows the `EventSink` trait. This adapter maps each event
//! to the Tauri call it used to make directly, keeping names and payloads
//! unchanged for the renderer. It owns a clone of the `AppHandle` so it can
//! outlive the command that created it, for example the background scanner.

use std::sync::Arc;

use serde_json::Value;
use swh_core::events::{EventSink, TRAY_TITLE_REFRESH};
use tauri::{AppHandle, Emitter, Manager, Runtime};

use crate::storage::AppState;
use crate::tray;

pub struct TauriEvents<R: Runtime> {
    app: AppHandle<R>,
}

impl<R: Runtime> TauriEvents<R> {
    pub fn new(app: &AppHandle<R>) -> Self {
        Self { app: app.clone() }
    }

    /// Shared handle for hosts that need to pass the sink across tasks.
    pub fn shared(app: &AppHandle<R>) -> Arc<dyn EventSink>
    where
        R: 'static,
    {
        Arc::new(Self::new(app))
    }
}

impl<R: Runtime> EventSink for TauriEvents<R> {
    fn emit(&self, event: &str, payload: Value) {
        if event == TRAY_TITLE_REFRESH {
            let state = self.app.state::<Arc<AppState>>();
            if let Err(error) = tray::refresh_title(&self.app, &state) {
                log::warn!("failed to refresh tray title: {error}");
            }
            return;
        }
        let _ = self.app.emit(event, payload);
    }
}
