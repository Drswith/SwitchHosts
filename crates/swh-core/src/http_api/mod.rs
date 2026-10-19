//! Local HTTP API used by the Alfred workflow and scripts.
//!
//! Routes, toggle semantics and the listener lifecycle live in the core so
//! every host serves the same contract. The host supplies two things through
//! [`ApiHost`]: whether a renderer owns the apply pipeline, and how to ask it
//! to flip an entry. Without a renderer the core applies the toggle itself.
//!
//! The routes answer `200` even for failures; callers discriminate on the
//! body. See `routes.rs` for the table.

pub mod routes;
pub mod server;

use std::sync::Mutex;

use serde_json::json;
use tokio::runtime::Handle;

use crate::storage::{AppConfig, StorageError};

pub use routes::{ApiHost, HttpContext, NoRenderer};
pub use server::{ApiError, Endpoint, Status};

/// Owns the HTTP listener. A host keeps one for the life of the process.
pub struct HttpApi {
    server: Mutex<server::Server>,
}

impl HttpApi {
    pub const fn new() -> Self {
        Self {
            server: Mutex::new(server::Server::new()),
        }
    }

    /// Apply `config` to the listener. `persist` runs while the listener
    /// change is reserved, so a failed save never leaves a stale server.
    /// Emits `http_api_status_changed` after every attempt.
    pub fn configure(
        &self,
        runtime: &Handle,
        ctx: HttpContext,
        config: &AppConfig,
        persist: impl FnOnce() -> Result<(), StorageError>,
    ) -> Result<(), StorageError> {
        let endpoint = config.http_api_on.then_some(Endpoint {
            port: config.http_api_port,
            only_local: config.http_api_only_local,
        });
        let events = ctx.events.clone();
        let router = routes::router(ctx);
        let result = self
            .server
            .lock()
            .expect("http server mutex poisoned")
            .configure(runtime, router, endpoint, persist);
        events.emit("http_api_status_changed", json!({ "_args": [] }));
        result
    }

    pub fn status(&self) -> Status {
        self.server.lock().expect("http server mutex poisoned").status()
    }

    /// Stop serving. Blocks until the listener socket is closed, so call it
    /// from outside the server runtime.
    pub fn stop(&self, runtime: &Handle) {
        self.server.lock().expect("http server mutex poisoned").stop(runtime);
    }
}

impl Default for HttpApi {
    fn default() -> Self {
        Self::new()
    }
}
