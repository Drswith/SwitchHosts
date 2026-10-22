//! Command surface for the native host.
//!
//! Each function takes the same positional `args` the renderer sends and
//! mirrors the Tauri command of the same name in upstream's
//! `src-tauri/src/commands.rs` (tracked in `crates/upstream-sync.txt`). The
//! FFI dispatcher is a thin wrapper over these.

use serde_json::{json, Value};

use std::path::Path;

use crate::apply;
use crate::events::{EventSink, TRAY_TITLE_REFRESH};
use crate::find::{self, FindOptions, FindReplaceOneArgs};
use crate::hosts_apply;
use crate::http;
use crate::import_export::{self, preview::{ImportError, Request, Sessions}};
use crate::refresh;
use crate::storage::{
    entries,
    manifest::{self, Manifest},
    transaction::{self, Target},
    tree_format::legacy_root_to_v5,
    AppState, StorageError, Trashcan,
};
use crate::toggle;

/// Positional arguments, as sent by the renderer adapter.
pub type Args = Vec<Value>;

// ---- small helpers ---------------------------------------------------------

pub fn load_manifest(state: &AppState) -> Result<Manifest, StorageError> {
    Manifest::load(&state.paths)
}

pub fn save_manifest(state: &AppState, m: &Manifest) -> Result<(), StorageError> {
    m.save(&state.paths)
}

pub fn load_trashcan(state: &AppState) -> Result<Trashcan, StorageError> {
    Trashcan::load(&state.paths.trashcan_file)
}

pub fn save_trashcan(state: &AppState, t: &Trashcan) -> Result<(), StorageError> {
    t.save(&state.paths.trashcan_file)
}

pub fn arg_str<'a>(args: &'a Args, index: usize, field: &'static str) -> Result<&'a str, StorageError> {
    args.get(index)
        .and_then(Value::as_str)
        .ok_or_else(|| StorageError::InvalidConfigValue {
            key: field.into(),
            reason: format!("expected a string at args[{index}]"),
        })
}

// ---- list / tree -----------------------------------------------------------

pub fn get_list(state: &AppState) -> Result<Value, StorageError> {
    let _guard = state.lock_store()?;
    let m = load_manifest(state)?;
    Ok(Value::Array(m.root))
}

pub fn get_item_from_list(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    let _guard = state.lock_store()?;
    let id = arg_str(args, 0, "id")?;
    let m = load_manifest(state)?;
    Ok(manifest::find_node(&m.root, id).unwrap_or(Value::Null))
}

/// Aggregate the content of the list the renderer passes in `args[0]`.
///
/// The list is intentionally not re-read from disk: the Apply button must
/// write whatever the user is looking at, including edits not yet saved.
pub fn get_content_of_list(state: &AppState, args: Args) -> Result<Value, StorageError> {
    let list_value = args.into_iter().next().unwrap_or(Value::Null);
    let list: Vec<Value> = match list_value {
        Value::Array(arr) => arr,
        Value::Null => Vec::new(),
        _ => {
            return Err(StorageError::InvalidConfigValue {
                key: "get_content_of_list.args[0]".into(),
                reason: "expected an array of host nodes".into(),
            });
        }
    };

    let remove_duplicate = {
        let cfg = state.config.lock().expect("config mutex poisoned");
        cfg.remove_duplicate_records
    };

    let _guard = state.lock_store()?;
    let content = hosts_apply::aggregate_selected_content(&list, &state.paths, remove_duplicate)?;
    Ok(json!(content))
}

/// Replace the saved tree with `args[0]`. `args[1]`, when present, is the
/// tree the caller last read; a mismatch means someone else changed it.
pub fn set_list(state: &AppState, args: Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let mut args = args.into_iter();
    let list = args.next().unwrap_or(Value::Null);
    let expected = args.next();
    let root = match list {
        Value::Array(arr) => arr,
        Value::Null => Vec::new(),
        _ => {
            return Err(StorageError::InvalidConfigValue {
                key: "set_list.args[0]".into(),
                reason: "expected an array of host nodes".into(),
            });
        }
    };
    let _guard = state.lock_store()?;
    let mut m = load_manifest(state)?;
    if let Some(expected) = expected {
        let expected = expected
            .as_array()
            .ok_or_else(|| StorageError::InvalidConfigValue {
                key: "set_list.args[1]".into(),
                reason: "expected the previously read array of host nodes".into(),
            })?;
        // Compare persisted fields, including collapse state, in canonical form.
        // Renderer defaults (e.g. an omitted `type`) must not cause conflicts.
        if legacy_root_to_v5(expected) != legacy_root_to_v5(&m.root) {
            return Err(StorageError::Conflict {
                reason: "The hosts list changed. Reload it and retry your edit.".into(),
            });
        }
    }
    // Reapplying the already saved configuration only needs the CAS check.
    // Do not make recovery depend on rewriting unchanged metadata on a full
    // or read-only disk.
    if legacy_root_to_v5(&root) == legacy_root_to_v5(&m.root) {
        return Ok(Value::Null);
    }
    m.root = root;
    transaction::run(&state.paths, vec![Target::State, Target::Manifest], || {
        save_manifest(state, &m)
    })?;
    Ok(Value::Null)
}

// ---- trashcan --------------------------------------------------------------

pub fn get_trashcan_list(state: &AppState) -> Result<Value, StorageError> {
    let _guard = state.lock_store()?;
    let t = load_trashcan(state)?;
    Ok(Value::Array(t.items))
}

// ---- trashcan writes ------------------------------------------------------

pub fn move_to_trashcan(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let id = arg_str(args, 0, "id")?.to_string();
    move_ids_to_trashcan(state, &[id])?;
    Ok(Value::Null)
}

pub fn move_many_to_trashcan(state: &AppState, args: Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let ids_value = args.into_iter().next().unwrap_or(Value::Null);
    let ids: Vec<String> = match ids_value {
        Value::Array(arr) => arr
            .into_iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect(),
        _ => {
            return Err(StorageError::InvalidConfigValue {
                key: "move_many_to_trashcan.args[0]".into(),
                reason: "expected an array of ids".into(),
            });
        }
    };
    move_ids_to_trashcan(state, &ids)?;
    Ok(Value::Null)
}

pub fn move_ids_to_trashcan(state: &AppState, ids: &[String]) -> Result<(), StorageError> {
    let _guard = state.lock_store()?;
    let mut m = load_manifest(state)?;
    let mut t = load_trashcan(state)?;
    for id in ids {
        if let Some((node, parent_id)) = manifest::remove_node(&mut m.root, id) {
            t.add_item(node, parent_id);
        }
    }
    transaction::run(
        &state.paths,
        vec![Target::State, Target::Manifest, Target::Trashcan],
        || {
            save_manifest(state, &m)?;
            save_trashcan(state, &t)
        },
    )
}

pub fn clear_trashcan(state: &AppState) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let _guard = state.lock_store()?;
    let mut t = load_trashcan(state)?;

    // Collect every content id under the trashed nodes, then delete the
    // corresponding entries/<id>.hosts files with the trashcan write.
    let mut content_ids = Vec::new();
    for item in &t.items {
        if let Some(data) = item.get("data") {
            manifest::collect_content_ids(std::slice::from_ref(data), &mut content_ids);
        }
    }
    let mut targets = vec![Target::Trashcan];
    targets.extend(content_ids.iter().cloned().map(Target::Entry));
    t.items.clear();
    transaction::run(&state.paths, targets, || {
        save_trashcan(state, &t)?;
        for cid in &content_ids {
            entries::delete_entry(&state.paths.entries_dir, cid)?;
        }
        Ok(())
    })?;
    Ok(Value::Null)
}

pub fn delete_item_from_trashcan(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let id = arg_str(args, 0, "id")?.to_string();
    let _guard = state.lock_store()?;
    let mut t = load_trashcan(state)?;
    let removed_item = t.remove_item(&id);
    let mut content_ids = Vec::new();
    if let Some(data) = removed_item.as_ref().and_then(|item| item.get("data")) {
        manifest::collect_content_ids(std::slice::from_ref(data), &mut content_ids);
    }
    let mut targets = vec![Target::Trashcan];
    targets.extend(content_ids.iter().cloned().map(Target::Entry));
    transaction::run(&state.paths, targets, || {
        save_trashcan(state, &t)?;
        for cid in &content_ids {
            entries::delete_entry(&state.paths.entries_dir, cid)?;
        }
        Ok(())
    })?;

    Ok(json!(removed_item.is_some()))
}

pub fn restore_item_from_trashcan(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let id = arg_str(args, 0, "id")?.to_string();
    let _guard = state.lock_store()?;
    let mut t = load_trashcan(state)?;
    let item = match t.remove_item(&id) {
        Some(item) => item,
        None => return Ok(json!(false)),
    };

    let parent_id = item
        .get("parent_id")
        .and_then(Value::as_str)
        .map(String::from);
    let node = item.get("data").cloned().unwrap_or(Value::Null);
    if node.is_null() {
        // Malformed trashcan entry: keep the shorter trashcan and report failure.
        save_trashcan(state, &t)?;
        return Ok(json!(false));
    }

    let mut m = load_manifest(state)?;
    manifest::insert_node(&mut m.root, node, parent_id.as_deref());
    transaction::run(
        &state.paths,
        vec![Target::State, Target::Manifest, Target::Trashcan],
        || {
            save_manifest(state, &m)?;
            save_trashcan(state, &t)
        },
    )?;
    Ok(json!(true))
}

// ---- hosts content ---------------------------------------------------------

pub fn get_hosts_content(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    let _guard = state.lock_store()?;
    let id = arg_str(args, 0, "id")?;
    let content = entries::read_entry(&state.paths.entries_dir, id)?;
    Ok(json!(content))
}

pub fn set_hosts_content(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let _guard = state.lock_store()?;
    let id = arg_str(args, 0, "id")?.to_string();
    let content = args
        .get(1)
        .and_then(Value::as_str)
        .ok_or_else(|| StorageError::InvalidConfigValue {
            key: "set_hosts_content.args[1]".into(),
            reason: "expected a string content at args[1]".into(),
        })?
        .to_string();
    entries::write_entry(&state.paths.entries_dir, &id, &content)?;
    Ok(Value::Null)
}

// ---- config ----------------------------------------------------------------

pub fn config_all(state: &AppState) -> Result<Value, StorageError> {
    let cfg = state.config.lock().expect("config mutex poisoned");
    Ok(cfg.to_flat_value())
}

pub fn config_get(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    let key =
        args.first()
            .and_then(Value::as_str)
            .ok_or_else(|| StorageError::InvalidConfigValue {
                key: "<arg0>".into(),
                reason: "config_get requires a string key as the first argument".into(),
            })?;
    let cfg = state.config.lock().expect("config mutex poisoned");
    Ok(cfg.get_key(key).unwrap_or(Value::Null))
}

// ---- remote refresh -------------------------------------------------------

/// Refresh one remote entry. Refresh failures come back as renderer-shaped
/// values rather than errors, so the caller can show them per entry.
pub async fn refresh_remote_hosts(
    state: &AppState,
    events: &dyn EventSink,
    args: &Args,
) -> Result<Value, String> {
    state.require_data_dir_usable().map_err(|e| e.to_string())?;
    let id = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| "refresh_remote_hosts: args[0] must be a string".to_string())?;
    Ok(match refresh::refresh_one(state, events, id).await {
        Ok(outcome) => outcome.into_renderer_value(),
        Err(error) => error.into_renderer_value(),
    })
}

/// Refresh every remote entry and return one result per id.
pub async fn refresh_all_remote_hosts(
    state: &AppState,
    events: &dyn EventSink,
) -> Result<Value, String> {
    state.require_data_dir_usable().map_err(|e| e.to_string())?;
    let results = refresh::refresh_all(state, events).await;
    let payload: Vec<Value> = results
        .into_iter()
        .map(|(id, outcome)| {
            let mut value = match outcome {
                Ok(outcome) => outcome.into_renderer_value(),
                Err(error) => error.into_renderer_value(),
            };
            if let Some(obj) = value.as_object_mut() {
                obj.insert("id".to_string(), json!(id));
            }
            value
        })
        .collect();
    Ok(Value::Array(payload))
}

// ---- import / export -----------------------------------------------------

/// Write a backup of the hosts data to `dest`. Returns the path written.
pub fn export_data(state: &AppState, dest: &Path) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let _guard = state.lock_store()?;
    import_export::export_to_file(dest, &state.paths)?;
    Ok(json!(dest.display().to_string()))
}

/// Parse a backup file and stage it as a preview. Nothing is written yet.
pub fn import_file(state: &AppState, sessions: &Sessions, path: &Path) -> Result<Value, ImportError> {
    state.require_data_dir_usable()?;
    let bytes = http::read_file_with_limit(path, http::MAX_IMPORT_BACKUP_BYTES)
        .map_err(ImportError::Invalid)?;
    let draft = import_export::preview::parse(&bytes)?;
    let name = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("import")
        .to_string();
    let _guard = state.lock_store()?;
    Ok(json!(sessions.prepare(draft, name, &state.paths)?))
}

/// Fetch a backup from `url` and stage it as a preview.
pub async fn import_url(state: &AppState, sessions: &Sessions, url: &str) -> Result<Value, ImportError> {
    state.require_data_dir_usable()?;
    let client = http::build_client(state).map_err(ImportError::Invalid)?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(http::request_error_message)
        .map_err(ImportError::Invalid)?;
    let status = response.status();
    if !status.is_success() {
        return Err(ImportError::Invalid(format!("error_{}", status.as_u16())));
    }
    let bytes = http::response_bytes_with_limit(response, http::MAX_IMPORT_BACKUP_BYTES)
        .await
        .map_err(ImportError::Invalid)?;
    let draft = import_export::preview::parse(&bytes)?;
    let name = reqwest::Url::parse(url)
        .ok()
        .and_then(|u| {
            u.path_segments()
                .and_then(|mut p| p.next_back())
                .map(str::to_string)
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "import".into());
    let name = name.strip_suffix(".json").unwrap_or(&name).to_string();
    let _guard = state.lock_store()?;
    Ok(json!(sessions.prepare(draft, name, &state.paths)?))
}

pub fn import_rebase(state: &AppState, sessions: &Sessions, token: &str) -> Result<Value, ImportError> {
    state.require_data_dir_usable()?;
    let _guard = state.lock_store()?;
    Ok(json!(sessions.rebase(token, &state.paths)?))
}

pub fn import_discard(sessions: &Sessions, token: &str) {
    sessions.discard(token);
}

/// Commit a staged import. Emits the same refresh events the renderer expects.
pub fn import_commit(
    state: &AppState,
    events: &dyn EventSink,
    sessions: &Sessions,
    request: Value,
) -> Result<Value, ImportError> {
    state.require_data_dir_usable()?;
    let request: Request = serde_json::from_value(request)
        .map_err(|_| ImportError::Invalid("invalid_data".into()))?;
    let result = {
        let _guard = state.lock_store()?;
        if state.application_recovery.is_pending() {
            return Err(ImportError::Invalid("application_recovery".into()));
        }
        sessions.commit(request, &state.paths)?
    };
    events.emit("reload_list", json!({ "_args": [] }));
    events.emit("tray_list_updated", json!({ "_args": [] }));
    // The import is committed even if refreshing the tray title fails.
    events.emit(TRAY_TITLE_REFRESH, json!({ "_args": [] }));
    Ok(result)
}

// ---- find and replace -----------------------------------------------------

/// Search every local and remote entry. `args`: keyword, optional options.
pub fn find_by(state: &AppState, args: &Args) -> Result<Value, String> {
    let keyword = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| "find_by: args[0] must be a string keyword".to_string())?;
    let options = find_options(args.get(1), "find_by")?;
    let items = find::find_in_manifest(state, keyword, &options)?;
    serde_json::to_value(items).map_err(|e| e.to_string())
}

/// Replace one match. `args[0]` is a request object (see `FindReplaceOneArgs`).
pub fn find_replace_one(state: &AppState, args: Args) -> Result<Value, String> {
    state.require_data_dir_usable().map_err(|e| e.to_string())?;
    let request: FindReplaceOneArgs = args
        .into_iter()
        .next()
        .ok_or_else(|| "find_replace_one: args[0] must be a request object".to_string())
        .and_then(|v| {
            serde_json::from_value(v).map_err(|e| format!("find_replace_one: invalid request: {e}"))
        })?;
    let replaced = find::replace_one_in_manifest(state, request)?;
    Ok(json!(replaced))
}

/// Replace every match. `args`: keyword, optional options, replacement text.
pub fn find_replace_all(state: &AppState, args: &Args) -> Result<Value, String> {
    state.require_data_dir_usable().map_err(|e| e.to_string())?;
    let keyword = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| "find_replace_all: args[0] must be a string keyword".to_string())?;
    let options = find_options(args.get(1), "find_replace_all")?;
    let replace_to = args
        .get(2)
        .and_then(Value::as_str)
        .ok_or_else(|| "find_replace_all: args[2] must be a string replacement".to_string())?;
    let outcome = find::replace_all_in_manifest(state, keyword, &options, replace_to)?;
    serde_json::to_value(outcome).map_err(|e| e.to_string())
}

fn find_options(value: Option<&Value>, command: &str) -> Result<FindOptions, String> {
    match value {
        Some(v) if !v.is_null() => serde_json::from_value(v.clone())
            .map_err(|e| format!("{command}: invalid options: {e}")),
        _ => Ok(FindOptions::default()),
    }
}

// ---- apply history (system hosts) -----------------------------------------

fn system_history_path(state: &AppState) -> std::path::PathBuf {
    state.paths.histories_dir.join("system-hosts.json")
}

/// Every recorded system hosts apply, as stored.
pub fn get_apply_history(state: &AppState) -> Result<Value, StorageError> {
    let _guard = state.lock_store()?;
    let path = system_history_path(state);
    let items = hosts_apply::history::load(&path)?;
    serde_json::to_value(items).map_err(|e| StorageError::serialize(path.display().to_string(), e))
}

/// Removes one apply record. `args[0]` is its id; returns whether one was removed.
pub fn delete_apply_history_item(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let id = arg_str(args, 0, "id")?;
    let _guard = state.lock_store()?;
    let removed = hosts_apply::history::delete_by_id(&system_history_path(state), id)?;
    Ok(json!(removed))
}

pub fn clear_apply_history(state: &AppState) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let _guard = state.lock_store()?;
    hosts_apply::history::save(&system_history_path(state), &[])?;
    Ok(Value::Null)
}

/// Changes how many apply records are kept. `args[0]` is `{limit, confirmation}`.
/// Without a matching confirmation the core reports `confirmation_required`
/// and nothing is trimmed.
pub fn update_apply_history_limit(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    #[derive(serde::Deserialize)]
    struct Request {
        limit: u32,
        confirmation: Option<hosts_apply::history::LimitConfirmation>,
    }
    let request: Request = serde_json::from_value(args.first().cloned().unwrap_or(Value::Null))
        .map_err(|e| StorageError::InvalidConfigValue {
            key: "history_limit".into(),
            reason: e.to_string(),
        })?;
    let result = hosts_apply::history::update_limit(state, request.limit, request.confirmation)?;
    serde_json::to_value(result).map_err(|e| StorageError::serialize("system-hosts.json", e))
}

// ---- data directory ----------------------------------------------------------

/// Where the data lives now, where the default is, whether a reset would change
/// anything, and the recovery state when the recorded folder is unusable.
pub fn data_dir_status(state: &AppState) -> Result<Value, StorageError> {
    let recovery = state.data_dir_recovery.as_ref().map(|r| match r {
        crate::storage::paths::DataDirRecovery::Missing(p) => json!({
            "kind": "missing",
            "path": p.display().to_string(),
        }),
        crate::storage::paths::DataDirRecovery::Invalid => json!({
            "kind": "invalid",
            "path": Value::Null,
        }),
    });
    Ok(json!({
        "active_dir": state.paths.root.display().to_string(),
        "default_dir": crate::storage::paths::default_root()?.display().to_string(),
        "can_reset": crate::storage::data_dir_pointer::pointer_exists(),
        "recovery": recovery,
    }))
}

/// What a folder the user picked would become: the default location (a reset)
/// or a custom data folder named `SwitchHosts.data` inside it. Creates nothing.
pub fn data_dir_plan(state: &AppState, picked: &Path) -> Result<Value, StorageError> {
    use crate::storage::{fs_copy, paths};
    let default = paths::default_root()?;
    let current = fs_copy::lexical_canonicalize(&state.paths.root);
    Ok(match paths::resolve_target_dir(picked, &default) {
        paths::TargetKind::Default => json!({
            "kind": "default",
            "data_dir": default.display().to_string(),
            "is_empty": true,
            "is_same_as_current": fs_copy::lexical_canonicalize(&default) == current,
        }),
        paths::TargetKind::Custom(final_dir) => json!({
            "kind": "custom",
            "data_dir": final_dir.display().to_string(),
            "is_empty": fs_copy::dir_is_empty_ignoring_meta(&final_dir),
            "is_same_as_current": fs_copy::lexical_canonicalize(&final_dir) == current,
        }),
    })
}

/// Switches the data directory to the folder the user picked. With `copy`, the
/// current data is merged into the new folder first; the source is never
/// changed. Choosing the default location resets to it. The caller must
/// restart the app to use the new folder; `restart` says so.
pub fn apply_data_dir(state: &AppState, raw_target: &Path, copy: bool) -> Result<Value, StorageError> {
    use crate::storage::{data_dir_pointer, fs_copy, paths};
    let default = paths::default_root()?;
    // A folder not named `SwitchHosts.data` gets that sub-folder appended, and the
    // default location is a reset. This stops a raw parent folder from becoming
    // the data folder itself.
    let (target, is_default) = match paths::resolve_target_dir(raw_target, &default) {
        paths::TargetKind::Default => (default.clone(), true),
        paths::TargetKind::Custom(p) => (p, false),
    };
    let current_root = state.paths.root.clone();
    let target_c = fs_copy::lexical_canonicalize(&target);
    let current_c = fs_copy::lexical_canonicalize(&current_root);

    if !is_default {
        if target_c == current_c {
            return Err(StorageError::InvalidDataDirChoice {
                reason: "the chosen folder is already the current data directory".into(),
            });
        }
        if target_c.starts_with(&current_c) || current_c.starts_with(&target_c) {
            return Err(StorageError::InvalidDataDirChoice {
                reason: "the chosen folder and the current data directory cannot contain each other".into(),
            });
        }
    }

    // Nothing to reset and not in recovery: already on the default location.
    if is_default && !data_dir_pointer::pointer_exists() && state.data_dir_recovery.is_none() {
        return Ok(json!({ "changed": false, "restart": false }));
    }

    if is_default {
        // Check the default is usable before forgetting the pointer, so a broken
        // default never becomes the next launch's root.
        paths::V5Paths::under(default.clone()).ensure_usable().map_err(|e| {
            StorageError::InvalidDataDirChoice {
                reason: format!("the default data directory is not usable: {e}"),
            }
        })?;
        data_dir_pointer::clear()?;
    } else {
        if copy {
            // Hold the store lock while copying so manifest and entry edits do not
            // interleave with the copy.
            let _guard = state.lock_store()?;
            fs_copy::copy_dir_recursive(&current_root, &target)?;
        }
        // The target must host the full layout and be writable before the pointer
        // moves, so the next launch never starts on a root that cannot store data.
        paths::V5Paths::under(target.clone()).ensure_usable().map_err(|e| {
            StorageError::InvalidDataDirChoice {
                reason: format!("the chosen folder can't store SwitchHosts data: {e}"),
            }
        })?;
        data_dir_pointer::save(&target)?;
    }
    Ok(json!({ "changed": true, "restart": true }))
}

/// Forgets the recorded data folder and returns to the default location. No data
/// is copied back. Without a recorded folder and outside recovery it changes nothing.
pub fn reset_data_dir(state: &AppState) -> Result<Value, StorageError> {
    use crate::storage::{data_dir_pointer, paths};
    if !data_dir_pointer::pointer_exists() && state.data_dir_recovery.is_none() {
        return Ok(json!({ "changed": false, "restart": false }));
    }
    paths::V5Paths::under(paths::default_root()?).ensure_usable().map_err(|e| {
        StorageError::InvalidDataDirChoice {
            reason: format!("the default data directory is not usable: {e}"),
        }
    })?;
    data_dir_pointer::clear()?;
    Ok(json!({ "changed": true, "restart": true }))
}

// ---- command history (cmd_after_hosts_apply) -----------------------------

fn cmd_history_path(state: &AppState) -> std::path::PathBuf {
    state.paths.histories_dir.join("cmd-after-apply.json")
}

/// Recorded runs of the after-apply command, as stored.
pub fn cmd_get_history_list(state: &AppState) -> Result<Value, StorageError> {
    let path = cmd_history_path(state);
    let items = hosts_apply::cmd_runner::load(&path)?;
    serde_json::to_value(items).map_err(|e| StorageError::serialize(path.display().to_string(), e))
}

/// Removes one recorded run. `args[0]` is its id; returns whether one was removed.
pub fn cmd_delete_history_item(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let id = arg_str(args, 0, "id")?;
    let removed = hosts_apply::cmd_runner::delete_by_id(&cmd_history_path(state), id)?;
    Ok(json!(removed))
}

pub fn cmd_clear_history(state: &AppState) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    hosts_apply::cmd_runner::clear(&cmd_history_path(state))?;
    Ok(Value::Null)
}

// ---- find and replace history ---------------------------------------------

/// Remembers a search keyword. `args[0]` is a `FindHistoryEntry`; returns the list.
pub fn find_add_history(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let invalid = |reason: &str| StorageError::InvalidConfigValue {
        key: "find_add_history.args[0]".into(),
        reason: reason.into(),
    };
    let value = args.first().cloned().ok_or_else(|| invalid("expected a FindHistoryEntry object"))?;
    let entry: find::FindHistoryEntry =
        serde_json::from_value(value).map_err(|_| invalid("expected a FindHistoryEntry object"))?;
    let all = find::add_find_history(state, entry)?;
    serde_json::to_value(all).map_err(|e| StorageError::serialize("find.json", e))
}

/// Replaces the whole keyword history. `args[0]` is an array of entries.
pub fn find_set_history(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let items: Vec<find::FindHistoryEntry> = match args.first() {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| serde_json::from_value::<find::FindHistoryEntry>(v.clone()).ok())
            .collect(),
        _ => Vec::new(),
    };
    find::set_find_history(state, &items)?;
    Ok(Value::Null)
}

/// Remembers a replacement text. `args[0]` is the text; returns the list.
pub fn find_add_replace_history(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let value = arg_str(args, 0, "find_add_replace_history")?.to_string();
    let all = find::add_replace_history(state, value)?;
    serde_json::to_value(all).map_err(|e| StorageError::serialize("replace.json", e))
}

/// Replaces the whole replacement-text history. `args[0]` is an array of strings.
pub fn find_set_replace_history(state: &AppState, args: &Args) -> Result<Value, StorageError> {
    state.require_data_dir_usable()?;
    let items: Vec<String> = match args.first() {
        Some(Value::Array(arr)) => arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
        _ => Vec::new(),
    };
    find::set_replace_history(state, &items)?;
    Ok(Value::Null)
}

// ---- config writes -------------------------------------------------------

/// Apply a partial preference update and persist it. The in-memory preference
/// is rolled back if the save fails. Side effects (login item, Dock icon, the
/// HTTP listener, theme) are the host's job; see `http_api_configure` for the
/// listener.
pub fn config_update(state: &AppState, patch: &Value) -> Result<Value, StorageError> {
    let _write = state.config_write_lock.lock().expect("config write mutex poisoned");
    let previous = state.config.lock().expect("config mutex poisoned").clone();
    let mut next = previous.clone();
    next.apply_partial(patch)?;
    *state.config.lock().expect("config mutex poisoned") = next;
    if let Err(error) = state.persist_config() {
        *state.config.lock().expect("config mutex poisoned") = previous;
        return Err(error);
    }
    Ok(Value::Null)
}

// ---- privileged helper ----------------------------------------------------

/// Registration state of the root helper that writes /etc/hosts silently.
pub fn helper_status() -> Value {
    json!({ "status": hosts_apply::helper_admin::status().as_code() })
}

/// Register the helper. Failures come back as values so the UI can explain them.
pub fn helper_install() -> Value {
    match hosts_apply::helper_admin::register() {
        Ok(status) => json!({ "success": true, "status": status.as_code() }),
        Err(error) => json!({
            "success": false,
            "status": hosts_apply::helper_admin::status().as_code(),
            "message": error.to_string(),
        }),
    }
}

pub fn helper_repair() -> Value {
    match hosts_apply::helper_admin::repair() {
        Ok(status) => json!({ "success": true, "status": status.as_code() }),
        Err(error) => json!({
            "success": false,
            "status": hosts_apply::helper_admin::status().as_code(),
            "message": error.to_string(),
        }),
    }
}

pub fn helper_uninstall() -> Value {
    match hosts_apply::helper_admin::unregister() {
        Ok(()) => json!({ "success": true, "status": hosts_apply::helper_admin::status().as_code() }),
        Err(error) => json!({
            "success": false,
            "status": hosts_apply::helper_admin::status().as_code(),
            "message": error.to_string(),
        }),
    }
}

// ---- system hosts (read only) ---------------------------------------------

/// The system hosts file as text. Read-only: writes go through the apply path.
pub fn get_system_hosts() -> Result<Value, StorageError> {
    let path = hosts_apply::write::system_hosts_path().map_err(|e| StorageError::Io {
        path: "system hosts path".to_string(),
        reason: e.to_string(),
    })?;
    hosts_apply::write::read_system_hosts(&path)
        .map(|s| json!(s))
        .map_err(|e| StorageError::Io {
            path: path.display().to_string(),
            reason: e.to_string(),
        })
}

// ---- update check (read only) --------------------------------------------

/// Whether `latest` is newer than `current`. Compares the numeric core first,
/// then treats a release as newer than the same version's pre-release.
pub fn is_newer_version(latest: &str, current: &str) -> bool {
    let (latest_core, latest_pre) = split_version(latest);
    let (current_core, current_pre) = split_version(current);
    let latest_nums = version_numbers(latest_core);
    let current_nums = version_numbers(current_core);
    if latest_nums != current_nums {
        return latest_nums > current_nums;
    }
    match (latest_pre, current_pre) {
        (None, Some(_)) => true,
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

fn split_version(version: &str) -> (&str, Option<&str>) {
    let trimmed = version.trim().trim_start_matches('v');
    match trimmed.split_once('-') {
        Some((core, pre)) => (core, Some(pre)),
        None => (trimmed, None),
    }
}

fn version_numbers(core: &str) -> Vec<u64> {
    core.split('.').map(|part| part.parse().unwrap_or(0)).collect()
}

/// Ask GitHub for the latest release. Returns the versions and the release
/// page; nothing is downloaded or installed.
pub async fn check_for_update(state: &AppState) -> Result<Value, String> {
    const LATEST: &str = "https://api.github.com/repos/oldj/SwitchHosts/releases/latest";
    let client = http::build_client(state)?;
    let response = client
        .get(LATEST)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(http::request_error_message)?;
    if !response.status().is_success() {
        return Err(format!("error_{}", response.status().as_u16()));
    }
    let text = response.text().await.map_err(|e| e.to_string())?;
    let body: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let latest = body
        .get("tag_name")
        .and_then(Value::as_str)
        .ok_or_else(|| "release has no tag_name".to_string())?
        .to_string();
    let current = env!("SWH_VERSION").to_string();
    Ok(json!({
        "current": current,
        "latest": latest,
        "update_available": is_newer_version(&latest, &current),
        "url": body.get("html_url").cloned().unwrap_or(Value::Null),
    }))
}

// ---- dispatch --------------------------------------------------------------

/// Run a command by name. Used by hosts that marshal commands as strings
/// (the native FFI). Errors are flattened to their display text.
pub async fn dispatch(
    state: &AppState,
    events: &dyn EventSink,
    sessions: &Sessions,
    command: &str,
    args: Args,
) -> Result<Value, String> {
    let result = match command {
        "version" => Ok(json!(env!("SWH_VERSION"))),
        "get_list" => get_list(state),
        "get_item_from_list" => get_item_from_list(state, &args),
        "get_content_of_list" => get_content_of_list(state, args),
        "set_list" => set_list(state, args),
        "get_trashcan_list" => get_trashcan_list(state),
        "find_by" => return find_by(state, &args),
        "find_replace_one" => return find_replace_one(state, args),
        "find_replace_all" => return find_replace_all(state, &args),
        "find_get_history" => find::get_find_history(state).map(|all| json!(all)),
        "find_get_replace_history" => find::get_replace_history(state).map(|all| json!(all)),
        "find_add_history" => find_add_history(state, &args),
        "find_set_history" => find_set_history(state, &args),
        "find_add_replace_history" => find_add_replace_history(state, &args),
        "find_set_replace_history" => find_set_replace_history(state, &args),
        "get_apply_history" => get_apply_history(state),
        "delete_apply_history_item" => delete_apply_history_item(state, &args),
        "clear_apply_history" => clear_apply_history(state),
        "update_apply_history_limit" => update_apply_history_limit(state, &args),
        "cmd_get_history_list" => cmd_get_history_list(state),
        "get_data_dir_status" => data_dir_status(state),
        "data_dir_plan" => {
            let picked = arg_str(&args, 0, "path").map_err(|e| e.to_string())?;
            data_dir_plan(state, Path::new(picked))
        }
        "apply_data_dir" => {
            let picked = arg_str(&args, 0, "path").map_err(|e| e.to_string())?;
            let copy = args.get(1).and_then(Value::as_bool).unwrap_or(false);
            apply_data_dir(state, Path::new(picked), copy)
        }
        "reset_data_dir" => reset_data_dir(state),
        "cmd_delete_history_item" => cmd_delete_history_item(state, &args),
        "cmd_clear_history" => cmd_clear_history(state),
        "move_to_trashcan" => move_to_trashcan(state, &args),
        "move_many_to_trashcan" => move_many_to_trashcan(state, args),
        "clear_trashcan" => clear_trashcan(state),
        "delete_item_from_trashcan" => delete_item_from_trashcan(state, &args),
        "restore_item_from_trashcan" => restore_item_from_trashcan(state, &args),
        "get_hosts_content" => get_hosts_content(state, &args),
        "set_hosts_content" => set_hosts_content(state, &args),
        "config_all" => config_all(state),
        "config_get" => config_get(state, &args),
        "check_for_update" => return check_for_update(state).await,
        "get_system_hosts" => get_system_hosts(),
        "helper_status" => Ok(helper_status()),
        "helper_install" => Ok(helper_install()),
        "helper_repair" => Ok(helper_repair()),
        "helper_uninstall" => Ok(helper_uninstall()),
        "config_update" => config_update(state, args.first().unwrap_or(&Value::Null)),
        "refresh_remote_hosts" => return refresh_remote_hosts(state, events, &args).await,
        "refresh_all_remote_hosts" => return refresh_all_remote_hosts(state, events).await,
        "export_data" => {
            let dest = arg_str(&args, 0, "path").map_err(|e| e.to_string())?;
            export_data(state, Path::new(dest))
        }
        "import_file" => {
            let path = arg_str(&args, 0, "path").map_err(|e| e.to_string())?;
            return import_file(state, sessions, Path::new(path)).map_err(|e| e.to_string());
        }
        "import_url" => {
            let url = arg_str(&args, 0, "url").map_err(|e| e.to_string())?;
            return import_url(state, sessions, url).await.map_err(|e| e.to_string());
        }
        "import_rebase" => {
            let token = arg_str(&args, 0, "id").map_err(|e| e.to_string())?;
            return import_rebase(state, sessions, token).map_err(|e| e.to_string());
        }
        "import_discard" => {
            let token = arg_str(&args, 0, "id").map_err(|e| e.to_string())?;
            import_discard(sessions, token);
            Ok(Value::Null)
        }
        "import_commit" => {
            let request = args.into_iter().next().unwrap_or(Value::Null);
            return import_commit(state, events, sessions, request).map_err(|e| e.to_string());
        }
        "toggle_item" => {
            let id = arg_str(&args, 0, "id").map_err(|e| e.to_string())?;
            return toggle::toggle_item(state, events, id)
                .await
                .map(|()| Value::Null)
                .map_err(|e| e.to_string());
        }
        // args[0]: the ids whose content changed, or null after a reorder.
        "reapply_saved_selection" => {
            let changed: Option<Vec<String>> = match args.into_iter().next() {
                None | Some(Value::Null) => None,
                Some(ids) => Some(serde_json::from_value(ids).map_err(|_| {
                    "reapply_saved_selection: args[0] must be an array of ids".to_string()
                })?),
            };
            return apply::reapply_saved_selection(state, events, changed.as_deref())
                .await
                .map(|applied| json!(applied))
                .map_err(|e| e.to_string());
        }
        other => return Err(format!("unknown command: {other}")),
    };
    result.map_err(|e| e.to_string())
}

#[cfg(test)]
mod version_tests {
    use super::is_newer_version;

    #[test]
    fn compares_numeric_cores() {
        assert!(is_newer_version("5.0.3", "5.0.2"));
        assert!(!is_newer_version("5.0.2", "5.0.3"));
        assert!(is_newer_version("5.10.0", "5.9.9"));
    }

    #[test]
    fn a_release_beats_its_own_prerelease() {
        assert!(is_newer_version("5.0.3", "5.0.3-beta.3"));
        assert!(!is_newer_version("5.0.3-beta.3", "5.0.3"));
        assert!(is_newer_version("5.0.3-beta.4", "5.0.3-beta.3"));
    }

    #[test]
    fn tolerates_a_v_prefix_and_equal_versions() {
        assert!(!is_newer_version("v5.0.2", "5.0.2"));
        assert!(is_newer_version("v5.0.3", "5.0.2"));
    }
}

#[cfg(test)]
mod history_tests {
    use super::*;
    use crate::hosts_apply::history::{self, ApplyHistoryItem};
    use crate::storage::{AppConfig, V5Paths};
    use std::sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Mutex};

    /// A fresh data root per test. A counter keeps parallel tests apart even when
    /// the clock returns the same value twice.
    fn state() -> AppState {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "swh-api-history-{}-{}",
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
        state.persist_config().unwrap();
        state
    }

    fn record(id: &str) -> ApplyHistoryItem {
        ApplyHistoryItem {
            id: id.into(),
            content: format!("1.1.1.1 {id}\n"),
            add_time_ms: 1,
            label: None,
        }
    }

    #[test]
    fn replace_history_keeps_unique_values_newest_last() {
        let state = state();
        for value in ["x", "y", "x"] {
            find_add_replace_history(&state, &vec![json!(value)]).unwrap();
        }
        assert_eq!(find::get_replace_history(&state).unwrap(), vec!["y", "x"]);
        find_set_replace_history(&state, &vec![json!(["only"])]).unwrap();
        assert_eq!(find::get_replace_history(&state).unwrap(), vec!["only"]);
    }

    #[test]
    fn find_history_deduplicates_and_rejects_bad_entries() {
        let state = state();
        let list = find_add_history(&state, &vec![json!({"value": "abc", "is_regexp": true})]).unwrap();
        assert_eq!(list.as_array().unwrap().len(), 1);
        let list = find_add_history(&state, &vec![json!({"value": "def"})]).unwrap();
        assert_eq!(list.as_array().unwrap().len(), 2);
        let list = find_add_history(&state, &vec![json!({"value": "abc"})]).unwrap();
        assert_eq!(list.as_array().unwrap().len(), 2, "same keyword replaces the old entry");
        assert!(find_add_history(&state, &vec![json!(42)]).is_err());
        assert!(find_add_history(&state, &vec![]).is_err());
        find_set_history(&state, &vec![json!([])]).unwrap();
        assert!(find::get_find_history(&state).unwrap().is_empty());
    }

    #[test]
    fn apply_history_lists_deletes_and_clears() {
        let state = state();
        let path = state.paths.histories_dir.join("system-hosts.json");
        history::save(&path, &[record("a"), record("b")]).unwrap();
        assert_eq!(get_apply_history(&state).unwrap().as_array().unwrap().len(), 2);

        assert_eq!(delete_apply_history_item(&state, &vec![json!("a")]).unwrap(), json!(true));
        assert_eq!(delete_apply_history_item(&state, &vec![json!("a")]).unwrap(), json!(false));
        assert_eq!(get_apply_history(&state).unwrap().as_array().unwrap().len(), 1);

        clear_apply_history(&state).unwrap();
        assert!(history::load(&path).unwrap().is_empty());
    }

    #[test]
    fn command_history_lists_deletes_and_clears() {
        let state = state();
        let path = cmd_history_path(&state);
        for id in ["run-a", "run-b"] {
            hosts_apply::cmd_runner::insert(
                &path,
                hosts_apply::cmd_runner::CommandRunResult {
                    id: id.into(),
                    success: true,
                    stdout: "ok\n".into(),
                    stderr: String::new(),
                    add_time_ms: 1,
                },
            )
            .unwrap();
        }
        assert_eq!(cmd_get_history_list(&state).unwrap().as_array().unwrap().len(), 2);
        assert_eq!(cmd_delete_history_item(&state, &vec![json!("run-a")]).unwrap(), json!(true));
        assert_eq!(cmd_get_history_list(&state).unwrap().as_array().unwrap().len(), 1);
        cmd_clear_history(&state).unwrap();
        assert!(hosts_apply::cmd_runner::load(&path).unwrap().is_empty());
    }

    #[test]
    fn lowering_the_limit_needs_confirmation_before_trimming() {
        let state = state();
        let path = state.paths.histories_dir.join("system-hosts.json");
        history::save(&path, &[record("a"), record("b")]).unwrap();

        let preview = update_apply_history_limit(&state, &vec![json!({"limit": 1, "confirmation": null})]).unwrap();
        assert_eq!(preview["confirmation_required"], json!(true));
        assert_eq!(preview["delete_count"], json!(1));
        assert_eq!(history::load(&path).unwrap().len(), 2, "a preview changes nothing");

        let applied = update_apply_history_limit(
            &state,
            &vec![json!({"limit": 1, "confirmation": {"previous_limit": 50, "delete_count": 1}})],
        )
        .unwrap();
        assert_eq!(applied["confirmation_required"], json!(false));
        assert_eq!(history::load(&path).unwrap().len(), 1);
        assert_eq!(state.config.lock().unwrap().history_limit, 1);
    }
}

/// Data-directory checks that never touch the recorded pointer file, which lives
/// in the user's real config folder. Tests here stop before any write.
#[cfg(test)]
mod data_dir_tests {
    use super::*;
    use crate::storage::{AppConfig, V5Paths};
    use std::sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Mutex};

    /// A state whose data root is `<temp>/<unique>/SwitchHosts.data`.
    fn state_at_custom_root() -> (AppState, std::path::PathBuf) {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let base = std::env::temp_dir().join(format!(
            "swh-api-datadir-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let root = base.join("SwitchHosts.data");
        let paths = V5Paths::under(root.clone());
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
        (state, base)
    }

    #[test]
    fn plan_names_a_custom_folder_and_appends_the_data_folder() {
        let (state, base) = state_at_custom_root();
        let other = base.join("elsewhere");
        std::fs::create_dir_all(&other).unwrap();

        let plan = data_dir_plan(&state, &other).unwrap();

        assert_eq!(plan["kind"], json!("custom"));
        assert_eq!(plan["data_dir"], json!(other.join("SwitchHosts.data").display().to_string()));
        assert_eq!(plan["is_empty"], json!(true));
        assert_eq!(plan["is_same_as_current"], json!(false));
    }

    #[test]
    fn choosing_the_current_folder_is_refused_before_any_write() {
        let (state, base) = state_at_custom_root();
        let err = apply_data_dir(&state, &base, false).unwrap_err();
        assert!(err.to_string().contains("already the current data directory"), "{err}");
    }

    #[test]
    fn nested_folders_are_refused_before_any_write() {
        let (state, _base) = state_at_custom_root();
        let inside = state.paths.root.join("inner");
        let err = apply_data_dir(&state, &inside, false).unwrap_err();
        assert!(err.to_string().contains("cannot contain each other"), "{err}");
    }
}
