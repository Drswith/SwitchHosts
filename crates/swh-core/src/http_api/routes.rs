//! Route handlers for the local HTTP API.
//!
//! | Method | Path                    | Body |
//! |--------|-------------------------|------|
//! | GET    | `/`                     | `Hello SwitchHosts!` |
//! | GET    | `/remote-test`          | `# remote-test` and a timestamp |
//! | GET    | `/api/list`             | `{success, data: flat_list}` |
//! | GET    | `/api/toggle?id=<id>`   | `ok`, `bad id.`, `not found.`, or a terse failure |
//! | GET    | `/api/refresh?id=<id>`  | `{success, changed, data}` or `{success: false, code, message}` |
//!
//! Every route answers `200`. Callers discriminate on the body, which is what
//! the Electron build did and what the Alfred workflow expects.
//!
//! Toggle: when a renderer is available the handler asks it to flip the entry
//! (`ApiHost::request_renderer_toggle`) so its apply pipeline and selection
//! rules run as usual. Otherwise the core applies the toggle itself through
//! `toggle::toggle_item`, which owns the write, compensation and history.
//!
//! Refresh: always handled by the core, which writes the entry and reports
//! the real outcome. Applying the new content to the system file is up to the
//! host, which gets `hosts_content_changed` from the core.

use std::sync::Arc;

use axum::extract::{Query, State};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::get;
use axum::Router;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::events::{EventSink, TRAY_TITLE_REFRESH};
use crate::hosts_apply::HostsApplyError;
use crate::refresh::{self, RefreshError, RefreshOutcome};
use crate::storage::AppState;
use crate::toggle::{ensure_toggle_allowed, toggle_item, ToggleError};

/// Host hooks the HTTP API needs beyond storage.
pub trait ApiHost: Send + Sync {
    /// True while a renderer is alive to run the apply pipeline (upstream's
    /// Tauri app checks for its main window).
    fn renderer_available(&self) -> bool {
        false
    }

    /// Ask the renderer to flip `id` to `on`. Only called when
    /// [`ApiHost::renderer_available`] returned true.
    fn request_renderer_toggle(&self, id: &str, on: bool) {
        let _ = (id, on);
    }
}

/// A host with no renderer. Toggles always run in the backend.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoRenderer;

impl ApiHost for NoRenderer {}

/// Everything a handler needs. Cheap to clone; axum clones it per request.
#[derive(Clone)]
pub struct HttpContext {
    pub state: Arc<AppState>,
    pub events: Arc<dyn EventSink>,
    pub host: Arc<dyn ApiHost>,
}

pub(super) fn router(ctx: HttpContext) -> Router {
    Router::new()
        .route("/", get(home))
        .route("/remote-test", get(remote_test))
        .route("/api/list", get(api_list))
        .route("/api/toggle", get(api_toggle))
        .route("/api/refresh", get(api_refresh))
        .with_state(ctx)
}

async fn home() -> &'static str {
    "Hello SwitchHosts!"
}

async fn remote_test() -> String {
    let now = chrono::Local::now().format("%a %b %e %Y %H:%M:%S GMT%z");
    format!("# remote-test\n# {now}")
}

async fn api_list(State(ctx): State<HttpContext>) -> Response {
    match ctx.state.read_manifest() {
        Ok(manifest) => {
            let flat = flatten_root(&manifest.root);
            Json(json!({ "success": true, "data": flat })).into_response()
        }
        Err(e) => Json(json!({
            "success": false,
            "message": e.to_string(),
        }))
        .into_response(),
    }
}

#[derive(Deserialize)]
struct IdQuery {
    id: Option<String>,
}

async fn api_toggle(State(ctx): State<HttpContext>, Query(q): Query<IdQuery>) -> &'static str {
    let Some(id) = q.id.filter(|id| !id.is_empty()) else {
        return "bad id.";
    };
    log::info!("toggle: {id}");

    if ctx.host.renderer_available() {
        if let Err(error) = ensure_toggle_allowed(&ctx.state.application_recovery) {
            return error.as_body();
        }
        let manifest = match ctx.state.read_manifest() {
            Ok(m) => m,
            Err(e) => {
                log::warn!("manifest load failed: {e}");
                return "not found.";
            }
        };
        let Some(node) = find_node(&manifest.root, &id) else {
            return "not found.";
        };
        let on = node.get("on").and_then(Value::as_bool).unwrap_or(false);
        ctx.host.request_renderer_toggle(&id, !on);
        return "ok";
    }

    let result = toggle_item(&ctx.state, ctx.events.as_ref(), &id).await;
    // Publish failures too: compensation may restore the old file or leave a
    // recovery notice that a lazily created tray must display.
    ctx.events.emit(TRAY_TITLE_REFRESH, json!({ "_args": [] }));
    ctx.events.emit("system_hosts_updated", json!({ "_args": [] }));
    ctx.events.emit("tray_list_updated", json!({ "_args": [] }));

    match result {
        Ok(()) => "ok",
        Err(e) => {
            // A cancelled prompt is a deliberate user action, not a fault.
            if matches!(e, ToggleError::Apply(HostsApplyError::Cancelled)) {
                log::info!("toggle cancelled by the user: {id}");
            } else {
                log::warn!("toggle failed for {id}: {e}");
            }
            e.as_body()
        }
    }
}

async fn api_refresh(State(ctx): State<HttpContext>, Query(q): Query<IdQuery>) -> Response {
    let Some(id) = q.id.filter(|id| !id.is_empty()) else {
        return Json(bad_id_value()).into_response();
    };
    log::info!("refresh: {id}");

    // This handler writes to the data directory itself, so refuse while the
    // data directory is unresolved, as the `refresh_remote_hosts` command does.
    if let Err(e) = ctx.state.require_data_dir_usable() {
        let denied = RefreshError::Storage {
            message: e.to_string(),
        };
        return Json(denied.into_renderer_value()).into_response();
    }

    let result = refresh::refresh_one(&ctx.state, ctx.events.as_ref(), &id).await;
    Json(refresh_result_value(result)).into_response()
}

/// Same shape as the command, including `changed` because HTTP callers cannot
/// listen for events. Partial domain failures keep `success: false` so callers
/// can tell cached results from a full success.
fn refresh_result_value(result: Result<RefreshOutcome, RefreshError>) -> Value {
    match result {
        Ok(outcome) => outcome.into_renderer_value(),
        Err(e) => e.into_renderer_value(),
    }
}

/// A missing or empty `id` is the caller's mistake, not a lookup miss.
fn bad_id_value() -> Value {
    json!({
        "success": false,
        "code": "bad_id",
        "message": "query parameter `id` is required",
    })
}

// ---- tree helpers ----------------------------------------------------------

fn flatten_root(nodes: &[Value]) -> Vec<Value> {
    let mut out = Vec::new();
    walk(nodes, &mut out);
    out
}

fn walk(nodes: &[Value], out: &mut Vec<Value>) {
    for node in nodes {
        out.push(node.clone());
        if let Some(children) = node.get("children").and_then(Value::as_array) {
            walk(children, out);
        }
    }
}

fn find_node(nodes: &[Value], id: &str) -> Option<Value> {
    for node in nodes {
        if node.get("id").and_then(Value::as_str) == Some(id) {
            return Some(node.clone());
        }
        if let Some(children) = node.get("children").and_then(Value::as_array) {
            if let Some(found) = find_node(children, id) {
                return Some(found);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_recovery_rejects_http_toggle_before_any_write() {
        let recovery = crate::hosts_apply::recovery::ApplicationRecovery::default();
        assert!(ensure_toggle_allowed(&recovery).is_ok());
        recovery.record(vec![json!({"id":"a", "on":true})], "applied".into());
        assert!(matches!(
            ensure_toggle_allowed(&recovery),
            Err(ToggleError::RecoveryRequired)
        ));
        assert_eq!(
            ensure_toggle_allowed(&recovery).err().unwrap().as_body(),
            "recovery required."
        );
        recovery.begin();
        assert!(matches!(
            ensure_toggle_allowed(&recovery),
            Err(ToggleError::RecoveryRequired)
        ));
        assert!(recovery.is_pending());
    }

    fn tree_fixture() -> Vec<Value> {
        // root
        // ├── local-1
        // ├── folder-a
        // │   ├── local-2
        // │   └── folder-b
        // │       └── local-3
        // └── local-4
        json!([
            { "id": "local-1", "type": "local", "on": true },
            {
                "id": "folder-a",
                "type": "folder",
                "children": [
                    { "id": "local-2", "type": "local", "on": false },
                    {
                        "id": "folder-b",
                        "type": "folder",
                        "children": [
                            { "id": "local-3", "type": "local", "on": true },
                        ]
                    }
                ]
            },
            { "id": "local-4", "type": "local", "on": false },
        ])
        .as_array()
        .cloned()
        .unwrap()
    }

    #[test]
    fn flatten_root_emits_parents_before_descendants_in_dfs_order() {
        let flat = flatten_root(&tree_fixture());
        let ids: Vec<&str> = flat.iter().filter_map(|n| n.get("id")?.as_str()).collect();
        assert_eq!(
            ids,
            vec!["local-1", "folder-a", "local-2", "folder-b", "local-3", "local-4"]
        );
    }

    #[test]
    fn flatten_root_handles_empty_tree() {
        assert!(flatten_root(&[]).is_empty());
    }

    #[test]
    fn find_node_locates_top_level_id() {
        let n = find_node(&tree_fixture(), "local-4").unwrap();
        assert_eq!(n.get("type").and_then(Value::as_str), Some("local"));
    }

    #[test]
    fn find_node_recurses_into_nested_folders() {
        // Two levels deep — exercises the recursive arm.
        let n = find_node(&tree_fixture(), "local-3").unwrap();
        assert_eq!(n.get("on").and_then(Value::as_bool), Some(true));
    }

    #[test]
    fn find_node_returns_none_for_missing_id() {
        assert!(find_node(&tree_fixture(), "does-not-exist").is_none());
    }

    #[test]
    fn find_node_skips_folder_with_non_array_children_field() {
        // A malformed node whose `children` is not an array should not
        // panic and should not be treated as a parent.
        let nodes = json!([
            { "id": "weird", "children": "not-an-array" },
            { "id": "real", "type": "local" },
        ])
        .as_array()
        .cloned()
        .unwrap();
        assert!(find_node(&nodes, "real").is_some());
        assert!(find_node(&nodes, "missing").is_none());
    }

    #[tokio::test]
    async fn home_route_returns_static_greeting() {
        assert_eq!(home().await, "Hello SwitchHosts!");
    }

    #[tokio::test]
    async fn remote_test_route_starts_with_marker_and_carries_timestamp() {
        let body = remote_test().await;
        assert!(
            body.starts_with("# remote-test\n# "),
            "unexpected body prefix: {body:?}"
        );
        // Timestamp must be non-empty (the chrono format string is dynamic).
        let ts = &body["# remote-test\n# ".len()..];
        assert!(!ts.is_empty());
    }

    #[test]
    fn refresh_result_value_distinguishes_updated_from_unchanged() {
        let node = json!({ "id": "remote-1", "type": "remote" });

        let updated = refresh_result_value(Ok(RefreshOutcome::Updated { node: node.clone() }));
        assert_eq!(
            updated,
            json!({ "success": true, "changed": true, "data": node })
        );

        let unchanged = refresh_result_value(Ok(RefreshOutcome::Unchanged { node: node.clone() }));
        assert_eq!(
            unchanged,
            json!({ "success": true, "changed": false, "data": node })
        );
    }

    #[test]
    fn refresh_result_value_passes_error_codes_through() {
        for (err, code) in [
            (RefreshError::InvalidId, "invalid_id"),
            (RefreshError::NotRemote, "not_remote"),
            (RefreshError::NoUrl, "no_url"),
            (
                RefreshError::Fetch {
                    message: "HTTP 502".into(),
                },
                "fetch_failed",
            ),
        ] {
            let v = refresh_result_value(Err(err));
            assert_eq!(v.get("success").and_then(Value::as_bool), Some(false));
            assert_eq!(v.get("code").and_then(Value::as_str), Some(code));
            // The message must survive — Raycast / Alfred show it verbatim.
            assert!(
                v.get("message")
                    .and_then(Value::as_str)
                    .is_some_and(|m| !m.is_empty()),
                "missing message for {code}: {v}"
            );
        }
    }

    #[test]
    fn bad_id_value_is_not_confused_with_a_lookup_miss() {
        let v = bad_id_value();
        assert_eq!(v.get("success").and_then(Value::as_bool), Some(false));
        assert_eq!(v.get("code").and_then(Value::as_str), Some("bad_id"));
        // `invalid_id` is reserved for "the node doesn't exist".
        assert_ne!(v.get("code").and_then(Value::as_str), Some("invalid_id"));
    }
}
