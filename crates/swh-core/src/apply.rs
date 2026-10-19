//! Write an aggregated selection to the system hosts file, then record it.
//!
//! Order matters and matches the Tauri app: write, journal the change,
//! announce `system_hosts_updated`, ask the host to refresh its tray title,
//! and only then run `cmd_after_hosts_apply` (which may take up to 30s).

use serde_json::json;

use crate::events::{EventSink, TRAY_TITLE_REFRESH};
use crate::hosts_apply::{self, write::ApplyOutcome, HostsApplyError};
use crate::storage::AppState;

/// Apply `content` to the system hosts file.
///
/// Callers that need recovery bookkeeping (toggle, the renderer apply) wrap
/// this call; this function only performs the write and its side effects.
pub async fn apply_aggregated_content(
    state: &AppState,
    events: &dyn EventSink,
    content: &str,
) -> Result<ApplyOutcome, HostsApplyError> {
    let (write_mode, cmd_after_apply) = {
        let cfg = state.config.lock().expect("config mutex poisoned");
        (cfg.write_mode.clone(), cfg.cmd_after_hosts_apply.clone())
    };

    // The privileged write can block on an OS auth prompt for as long as the
    // user takes. Run it on the blocking pool so it never pins an async worker
    // shared with the HTTP server and other commands.
    let write_result = {
        let content = content.to_string();
        let write_mode = write_mode.clone();
        let backup_dir = state.paths.histories_dir.join("hosts-encoding-backups");
        tokio::task::spawn_blocking(move || {
            hosts_apply::apply_to_system_hosts(&content, &write_mode, &backup_dir)
        })
        .await
    };
    let outcome = match write_result {
        Ok(Ok(outcome)) => outcome,
        Ok(Err(error)) => {
            if !matches!(error, HostsApplyError::Cancelled) {
                log::warn!("apply failed: {error}");
            }
            return Err(error);
        }
        Err(error) => {
            log::warn!("apply task failed to run: {error}");
            return Err(HostsApplyError::Io {
                message: format!("apply task failed to run: {error}"),
            });
        }
    };

    if !outcome.unchanged {
        if let Err(error) = hosts_apply::history::record_change(
            state,
            &outcome.previous_content,
            &outcome.new_content,
        ) {
            log::warn!("failed to persist system hosts history: {error}");
            events.emit(
                "apply_history_error",
                json!({ "_args": [error.to_string()] }),
            );
        }
    }

    events.emit("system_hosts_updated", json!({ "_args": [] }));
    events.emit(TRAY_TITLE_REFRESH, json!({ "_args": [] }));

    // `cmd_after_hosts_apply` runs as the current user, never elevated. The
    // runner caps the wait at 30s; the result goes to its own journal and is
    // broadcast as `cmd_run_result`.
    if let Some(result) = hosts_apply::cmd_runner::run(&cmd_after_apply).await {
        let cmd_history_path = state.paths.histories_dir.join("cmd-after-apply.json");
        if let Err(error) = hosts_apply::cmd_runner::insert(&cmd_history_path, result.clone()) {
            log::warn!("failed to persist cmd-after-apply history: {error}");
        }
        match serde_json::to_value(&result) {
            Ok(payload) => events.emit("cmd_run_result", json!({ "_args": [payload] })),
            Err(error) => log::warn!("failed to serialise cmd-after-apply result: {error}"),
        }
    }

    Ok(outcome)
}
