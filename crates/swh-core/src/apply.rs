//! Write an aggregated selection to the system hosts file, then record it.
//!
//! Order matters and matches the Tauri app: write, journal the change,
//! announce `system_hosts_updated`, ask the host to refresh its tray title,
//! and only then run `cmd_after_hosts_apply` (which may take up to 30s).

use serde_json::{json, Value};

use crate::events::{EventSink, TRAY_TITLE_REFRESH};
use crate::hosts_apply::{self, write::ApplyOutcome, HostsApplyError};
use crate::storage::{manifest::{self, Manifest}, AppState};
use crate::toggle::{ensure_toggle_allowed, ToggleError};

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

/// Apply the saved selection again after entry content or the enabled order
/// changed, as upstream's renderer does on `hosts_content_changed` and after a
/// reorder (`applyChangedRemoteHostsToSystem`, List `onChange`). With
/// `changed`, nothing is written unless one of those entries is switched on.
/// Returns whether the system file was applied.
///
/// Shares the toggle's serialization and recovery bookkeeping: it waits for
/// an apply in progress, refuses while an earlier application is unresolved,
/// and never writes with an unset write mode. With `resolve_pending`, it is
/// the way out of that unresolved state (upstream's "apply again" notice):
/// it applies the saved selection anyway, and a verified write clears it.
pub async fn reapply_saved_selection(
    state: &AppState,
    events: &dyn EventSink,
    changed: Option<&[String]>,
    resolve_pending: bool,
) -> Result<bool, ToggleError> {
    let recovery = &state.application_recovery;
    let _apply_guard = recovery.lock_apply().await;
    state.require_data_dir_usable()?;
    let (write_mode, remove_duplicate) = {
        let config = state.config.lock().expect("config mutex poisoned");
        (config.write_mode.clone(), config.remove_duplicate_records)
    };
    if write_mode.is_empty() {
        return Ok(false);
    }
    let content = {
        let _guard = state.lock_store()?;
        let saved = Manifest::load(&state.paths)?;
        if let Some(ids) = changed {
            let is_on = |id: &String| {
                manifest::find_node(&saved.root, id)
                    .and_then(|node| node.get("on").and_then(Value::as_bool))
                    .unwrap_or(false)
            };
            if !ids.iter().any(is_on) {
                return Ok(false);
            }
        }
        hosts_apply::aggregate_selected_content(&saved.root, &state.paths, remove_duplicate)?
    };
    // Checked only once there is something to write, so edits to entries that
    // are off never report the unresolved state.
    if !resolve_pending {
        ensure_toggle_allowed(recovery)?;
    }

    recovery.begin();
    let outcome = match apply_aggregated_content(state, events, &content).await {
        Ok(outcome) => outcome,
        Err(error) => {
            recovery.apply_failed();
            return Err(ToggleError::Apply(error));
        }
    };
    if recovery.finish(&outcome.new_content).is_some() {
        return Err(ToggleError::RecoveryRequired);
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::NoopEvents;
    use crate::storage::{AppConfig, V5Paths};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::Mutex;

    /// A fresh data root holding one local entry `a` (on when `on`). Built
    /// directly, so no fallback can reach a real data folder.
    fn state_with_entry(on: bool) -> AppState {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "swh-reapply-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let paths = V5Paths::under(root);
        paths.ensure_dirs().unwrap();
        let state = AppState {
            paths,
            config: Mutex::new(AppConfig::default()),
            store_lock: Mutex::new(()),
            application_recovery: Default::default(),
            config_write_lock: Mutex::new(()),
            update_check_lock: tokio::sync::Mutex::new(()),
            is_will_quit: AtomicBool::new(false),
            last_geometry_persist_ms: AtomicU64::new(0),
            data_dir_recovery: None,
        };
        let mut saved = Manifest::load(&state.paths).unwrap();
        saved.root = vec![json!({ "id": "a", "type": "local", "title": "a", "on": on })];
        saved.save(&state.paths).unwrap();
        state
    }

    fn ids(list: &[&str]) -> Vec<String> {
        list.iter().map(|id| id.to_string()).collect()
    }

    // Each test leaves an earlier application unresolved, so a check that
    // stopped working fails the test at the recovery refusal and never
    // reaches the real system file.

    #[tokio::test]
    async fn changes_to_entries_that_are_off_write_nothing() {
        let state = state_with_entry(false);
        state.application_recovery.begin();
        let changed = ids(&["a", "missing"]);
        let applied = reapply_saved_selection(&state, &NoopEvents, Some(&changed), false)
            .await
            .unwrap();
        assert!(!applied);
    }

    #[tokio::test]
    async fn an_unset_write_mode_writes_nothing() {
        let state = state_with_entry(true);
        state.config.lock().unwrap().write_mode.clear();
        state.application_recovery.begin();
        let applied = reapply_saved_selection(&state, &NoopEvents, Some(&ids(&["a"])), false)
            .await
            .unwrap();
        assert!(!applied);
    }

    #[tokio::test]
    async fn a_pending_application_is_refused_before_any_write() {
        let state = state_with_entry(true);
        state.application_recovery.begin();
        let result = reapply_saved_selection(&state, &NoopEvents, Some(&ids(&["a"])), false).await;
        assert!(matches!(result, Err(ToggleError::RecoveryRequired)));
    }
}
