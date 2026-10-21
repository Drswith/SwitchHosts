//! `AppState::bootstrap_at`: upstream's `AppState::bootstrap` against an
//! explicit root, skipping the data-dir pointer lookup. Used by the native
//! FFI and by tests.
//!
//! Upstream's `storage/mod.rs` is compiled in place and stays untouched, so
//! this lives here as an inherent impl in the same crate. The body mirrors
//! everything `bootstrap` does after `paths::resolve_root()`; keep it in step
//! with upstream (tracked in `crates/upstream-sync.txt`).

use std::sync::atomic::{AtomicBool, AtomicU64};
use std::sync::Mutex;

use crate::storage::{paths, transaction, AppConfig, AppState, StorageError, V5Paths};

impl AppState {
    pub fn bootstrap_at(
        mut paths: V5Paths,
        mut data_dir_recovery: Option<paths::DataDirRecovery>,
    ) -> Result<Self, StorageError> {
        // If the resolved root can't host the v5 layout — a file blocking a
        // required directory (e.g. a plain file named `entries`), a read-only
        // volume, or a read-only sub-dir — handle it without crashing here
        // (bootstrap is `.expect()`ed at the app entry). `ensure_usable`
        // probes each v5 dir for writability, not just existence.
        if let Err(e) = paths.ensure_usable() {
            let default = paths::default_root()?;
            if paths.root == default {
                // The active root IS the default. Only a *normal* startup (no
                // recovery) is truly unrecoverable here. If we are ALREADY in
                // recovery (pointer invalid / custom dir gone), the default is
                // just a fallback to host the recovery dialog — an unusable
                // default must NOT abort startup, or the user can never reach
                // "Choose New Folder". The dialog and an in-memory default
                // config don't require a writable default, so prepare it
                // best-effort and carry on.
                if data_dir_recovery.is_none() {
                    return Err(e);
                }
                log::warn!(
                    "default fallback root is also unusable ({e}); starting in recovery so the user can choose a new location"
                );
                let _ = paths.ensure_dirs();
            } else {
                // A recorded custom dir can't host the layout: fall back to the
                // default and enter recovery so the dialog handles it.
                log::warn!(
                    "custom data directory {} cannot host the data layout ({e}); falling back to default",
                    paths.root.display()
                );
                data_dir_recovery = Some(paths::DataDirRecovery::Missing(paths.root.clone()));
                paths = V5Paths::under(default);
                // Best-effort: even if the default is also unusable, start in
                // recovery so the user can pick a new location (never abort).
                if let Err(e2) = paths.ensure_dirs() {
                    log::warn!(
                        "default fallback root is also unusable ({e2}); starting in recovery anyway"
                    );
                }
            }
        }
        paths.cleanup_tmp_files();

        if let Some(recovery) = &data_dir_recovery {
            log::warn!(
                "custom data directory unavailable ({recovery:?}) — using default root and skipping migration; the user will be prompted"
            );
        } else {
            transaction::recover(&paths)?;
            let outcome = crate::migration::run_if_needed(&paths)?;
            log::info!("migration outcome: {outcome:?}");
        }

        let config = AppConfig::load(&paths.config_file);
        if data_dir_recovery.is_none() {
            let maintenance = AppConfig::load_checked(&paths.config_file).and_then(|cfg| {
                crate::hosts_apply::history::enforce_limit(
                    &paths.histories_dir.join("system-hosts.json"),
                    cfg.history_limit,
                )
            });
            if let Err(e) = maintenance {
                log::warn!("history retention maintenance skipped; original files retained: {e}");
            }
        }
        Ok(Self {
            paths,
            config: Mutex::new(config),
            store_lock: Mutex::new(()),
            application_recovery: Default::default(),
            config_write_lock: Mutex::new(()),
            update_check_lock: tokio::sync::Mutex::new(()),
            is_will_quit: AtomicBool::new(false),
            last_geometry_persist_ms: AtomicU64::new(0),
            data_dir_recovery,
        })
    }
}
