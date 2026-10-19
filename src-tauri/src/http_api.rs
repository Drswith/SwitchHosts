//! Tauri host for the local HTTP API.
//!
//! Routes, toggle semantics and the listener live in `swh_core::http_api`.
//! This file supplies the one host fact the core cannot know, whether the main
//! window is alive to run the renderer's apply pipeline, and forwards renderer
//! toggles as the `toggle_item` event.

use std::sync::Arc;

use serde_json::json;
use swh_core::http_api::{ApiHost, HttpApi, HttpContext, Status};
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::events::TauriEvents;
use crate::lifecycle::MAIN_WINDOW_LABEL;
use crate::storage::{AppConfig, AppState, StorageError};

static API: HttpApi = HttpApi::new();

struct TauriApiHost {
    app: AppHandle<Wry>,
}

impl ApiHost for TauriApiHost {
    fn renderer_available(&self) -> bool {
        self.app.get_webview_window(MAIN_WINDOW_LABEL).is_some()
    }

    fn request_renderer_toggle(&self, id: &str, on: bool) {
        let _ = self.app.emit("toggle_item", json!({ "_args": [id, on] }));
    }
}

/// Called at startup and from the blocking config writer.
pub fn configure(
    app: AppHandle<Wry>,
    config: &AppConfig,
    persist: impl FnOnce() -> Result<(), StorageError>,
) -> Result<(), StorageError> {
    let state = app.state::<Arc<AppState>>().inner().clone();
    let ctx = HttpContext {
        state,
        events: TauriEvents::shared(&app),
        host: Arc::new(TauriApiHost { app: app.clone() }),
    };
    API.configure(tauri::async_runtime::handle().inner(), ctx, config, persist)
}

pub fn status() -> Status {
    API.status()
}
