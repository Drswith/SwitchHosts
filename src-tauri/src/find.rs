//! Find / replace window plumbing. The search and replace logic lives in
//! `swh_core::find` and is re-exported here for the window commands.
//!
//! Phase 2.D scope:
//!
//! - Lazy-create the `find` webview (route `#/find`) on first
//!   `find_show` invocation. Closing the window destroys it; the next
//!   `find_show` invocation creates a fresh webview.
//! - Search content of every local/remote node in the manifest. Group
//!   and folder nodes are skipped (Electron does the same — they have
//!   no own content, only references).
//! - Persist find / replace history to
//!   `internal/histories/find.json` and `internal/histories/replace.json`,
//!   capped at 20 entries (matches Electron's `MAX_LENGTH = 20`).
//!
//! On-disk shape mirrors the renderer's `IFindHistoryData` /
//! `string[]` types one-for-one so the existing `pages/find.tsx`
//! consumers work without changes.

pub use swh_core::find::*;

use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use tauri::webview::WebviewWindowBuilder;
use tauri::{AppHandle, EventId, Listener, Manager, Runtime, Theme, WebviewUrl};

use crate::{
    i18n,
    storage::AppState,
    window_theme::{background_color_for_theme, configured_theme},
};

pub const FIND_WINDOW_LABEL: &str = "find";
const FIND_WINDOW_READY_EVENT: &str = "find_window_ready";

const FIND_WINDOW_WIDTH: f64 = 480.0;
const FIND_WINDOW_HEIGHT: f64 = 400.0;
const FIND_WINDOW_MIN_WIDTH: f64 = 400.0;
const FIND_WINDOW_MIN_HEIGHT: f64 = 400.0;
const FIND_WINDOW_READY_FALLBACK_MS: u64 = 1500;

/// Per-window state for the renderer-ready gate. A new instance is
/// installed every time we create a fresh find webview; on re-create we
/// `abandon()` the previous one so its listener and fallback timer
/// become no-ops and can't accidentally show an unrelated window.
struct FindGate {
    did_show: Arc<AtomicBool>,
    listener_id: Arc<Mutex<Option<EventId>>>,
}

impl FindGate {
    /// Mark this gate as superseded so any in-flight handler (listener
    /// or fallback timer) takes its early-return branch on next fire.
    fn abandon<R: Runtime>(&self, app: &AppHandle<R>) {
        self.did_show.store(true, Ordering::SeqCst);
        if let Some(id) = self
            .listener_id
            .lock()
            .expect("find listener mutex poisoned")
            .take()
        {
            app.unlisten(id);
        }
    }

    fn is_pending(&self) -> bool {
        !self.did_show.load(Ordering::SeqCst)
    }
}

static FIND_GATE: Mutex<Option<FindGate>> = Mutex::new(None);

/// Bring the find webview to the front, lazy-creating it the first time.
/// A newly-created webview stays hidden until the renderer applies its
/// theme and emits `find_window_ready`; after a user closes it, the next
/// call creates a fresh one.
pub fn show_find_window<R: Runtime + 'static>(app: &AppHandle<R>) -> Result<(), tauri::Error> {
    if let Some(window) = app.get_webview_window(FIND_WINDOW_LABEL) {
        // Existing window. If its ready gate is still pending the
        // listener/fallback will show it; don't preempt them or we'd
        // re-introduce the dark-theme flash this gate exists to avoid.
        let pending = FIND_GATE
            .lock()
            .expect("find gate mutex poisoned")
            .as_ref()
            .map(|g| g.is_pending())
            .unwrap_or(false);
        if pending {
            return Ok(());
        }
        show_find_window_now(&window)?;
        return Ok(());
    }

    // Window was destroyed (or never existed). Abandon any leftover
    // gate from a previous lifecycle so a stale listener/fallback can't
    // race against the new window we're about to create.
    {
        let mut slot = FIND_GATE.lock().expect("find gate mutex poisoned");
        if let Some(old) = slot.take() {
            old.abandon(app);
        }
    }

    let window = create_find_window(app)?;
    let gate = install_find_window_ready_handlers(app, &window);
    *FIND_GATE.lock().expect("find gate mutex poisoned") = Some(gate);
    Ok(())
}

pub fn refresh_find_window_title<R: Runtime>(app: &AppHandle<R>) {
    let Some(window) = app.get_webview_window(FIND_WINDOW_LABEL) else {
        return;
    };
    let _ = window.set_title(i18n::find_window_title(app));
    hide_find_window_menu(&window);
}

pub fn set_find_window_title<R: Runtime>(
    app: &AppHandle<R>,
    title: &str,
) -> Result<(), tauri::Error> {
    let Some(window) = app.get_webview_window(FIND_WINDOW_LABEL) else {
        return Ok(());
    };
    window.set_title(title)
}

fn show_find_window_now<R: Runtime>(window: &tauri::WebviewWindow<R>) -> Result<(), tauri::Error> {
    window.unminimize().ok();
    window.show()?;
    window.set_focus()?;
    Ok(())
}

fn show_find_window_once<R: Runtime>(
    app: &AppHandle<R>,
    window: &tauri::WebviewWindow<R>,
    did_show: &AtomicBool,
    listener_id: &Arc<Mutex<Option<EventId>>>,
) {
    // `compare_exchange` here doubles as the "abandoned" check: when a
    // newer window supersedes us, the old gate's `did_show` is forced
    // to true by `FindGate::abandon`, so this exchange returns Err and
    // we exit without touching anything.
    if did_show
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }
    if let Err(e) = show_find_window_now(window) {
        // Reset so the fallback (or a future caller) can try again.
        did_show.store(false, Ordering::SeqCst);
        log::warn!("failed to show find window: {e}");
        return;
    }

    unlisten_find_window_ready(app, listener_id);
}

fn unlisten_find_window_ready<R: Runtime>(
    app: &AppHandle<R>,
    listener_id: &Arc<Mutex<Option<EventId>>>,
) {
    if let Some(id) = listener_id
        .lock()
        .expect("find listener mutex poisoned")
        .take()
    {
        app.unlisten(id);
    }
}

fn install_find_window_ready_handlers<R: Runtime + 'static>(
    app: &AppHandle<R>,
    window: &tauri::WebviewWindow<R>,
) -> FindGate {
    let did_show = Arc::new(AtomicBool::new(false));
    let listener_id = Arc::new(Mutex::new(None));

    let ready_app = app.clone();
    let ready_window = window.clone();
    let ready_flag = did_show.clone();
    let ready_listener_id = listener_id.clone();
    let id = app.listen(FIND_WINDOW_READY_EVENT, move |event| {
        show_find_window_once(&ready_app, &ready_window, &ready_flag, &ready_listener_id);
        ready_app.unlisten(event.id());
    });
    *listener_id.lock().expect("find listener mutex poisoned") = Some(id);

    let fallback_app = app.clone();
    let fallback_window = window.clone();
    let fallback_flag = did_show.clone();
    let fallback_listener_id = listener_id.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(FIND_WINDOW_READY_FALLBACK_MS));
        if fallback_flag.load(Ordering::SeqCst) {
            return;
        }

        let app = fallback_app.clone();
        let window = fallback_window.clone();
        let flag = fallback_flag.clone();
        let listener_id = fallback_listener_id.clone();
        // Show the exact window this gate was created for, never
        // `app.get_webview_window(LABEL)` — after close-then-reopen the
        // label resolves to a brand-new window whose renderer hasn't
        // emitted ready yet, and showing it would re-introduce the
        // flash. If the captured window has been destroyed, the show
        // call simply fails and we log + bail.
        let _ = fallback_app.run_on_main_thread(move || {
            show_find_window_once(&app, &window, &flag, &listener_id);
        });
    });

    FindGate {
        did_show,
        listener_id,
    }
}

#[cfg_attr(target_os = "macos", allow(unused_variables))]
fn hide_find_window_menu<R: Runtime>(window: &tauri::WebviewWindow<R>) {
    #[cfg(not(target_os = "macos"))]
    if let Err(e) = window.hide_menu() {
        log::warn!("failed to hide find window menu: {e}");
    }
}

fn create_find_window<R: Runtime + 'static>(
    app: &AppHandle<R>,
) -> Result<tauri::WebviewWindow<R>, tauri::Error> {
    let url = WebviewUrl::App("#/find".into());
    let configured_theme = configured_theme(app.state::<Arc<AppState>>().inner());
    let initial_theme = configured_theme.unwrap_or(Theme::Light);
    let builder = WebviewWindowBuilder::new(app, FIND_WINDOW_LABEL, url)
        .title(i18n::find_window_title(app))
        .inner_size(FIND_WINDOW_WIDTH, FIND_WINDOW_HEIGHT)
        .min_inner_size(FIND_WINDOW_MIN_WIDTH, FIND_WINDOW_MIN_HEIGHT)
        .resizable(true)
        .maximizable(false)
        .minimizable(false)
        .skip_taskbar(true)
        .theme(configured_theme)
        .background_color(background_color_for_theme(initial_theme))
        .visible(false);

    #[cfg(target_os = "macos")]
    let builder = builder.title_bar_style(tauri::TitleBarStyle::Transparent);

    let window = builder.build()?;

    if let Ok(theme) = window.theme() {
        let _ = window.set_background_color(Some(background_color_for_theme(theme)));
    }
    hide_find_window_menu(&window);

    Ok(window)
}

#[cfg(test)]
mod tests {
    use super::*;
    use regex::Regex;
    use crate::storage::{entries, manifest::Manifest};
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::Mutex;

    use serde_json::json;

    use crate::storage::{AppConfig, V5Paths};

    fn re(pattern: &str) -> Regex {
        Regex::new(pattern).unwrap()
    }

    fn temp_state(name: &str) -> AppState {
        let root = std::env::temp_dir().join(format!(
            "switchhosts-find-test-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let paths = V5Paths::under(root);
        paths.ensure_dirs().unwrap();
        AppState {
            paths,
            config: Mutex::new(AppConfig::default()),
            store_lock: Mutex::new(()),
            application_recovery: Default::default(),
            config_write_lock: Mutex::new(()),
            update_check_lock: tokio::sync::Mutex::new(()),
            is_will_quit: AtomicBool::new(false),
            last_geometry_persist_ms: AtomicU64::new(0),
            data_dir_recovery: None,
        }
    }

    #[test]
    fn positions_are_utf16_for_non_ascii_prefix() {
        // "前缀" is 6 bytes / 2 UTF-16 units; "😀" is 4 bytes / 2 UTF-16
        // units (surrogate pair). The byte offset of "match" is 10 but
        // CodeMirror sees it at UTF-16 index 4.
        let content = "前缀😀match";
        let positions = find_positions_in_content(content, &re("match"));
        assert_eq!(positions.len(), 1);
        let p = &positions[0];
        assert_eq!(p.start, 4);
        assert_eq!(p.end, 9);
        assert_eq!(p.line_pos, 4);
        assert_eq!(p.end_line_pos, 9);
        assert_eq!(p.match_text, "match");
    }

    #[test]
    fn line_pos_resets_on_each_line() {
        let content = "abc\n中文 abc";
        let positions = find_positions_in_content(content, &re("abc"));
        assert_eq!(positions.len(), 2);
        assert_eq!(positions[0].line, 1);
        assert_eq!(positions[0].line_pos, 0);
        assert_eq!(positions[1].line, 2);
        // "中文 " is 3 UTF-16 units before the second "abc"
        assert_eq!(positions[1].line_pos, 3);
    }

    #[test]
    fn multiline_match_reports_end_line_and_column() {
        let content = "before α\nβ after";
        let positions = find_positions_in_content(content, &re("α\nβ"));
        assert_eq!(positions.len(), 1);
        let p = &positions[0];
        assert_eq!(p.line, 1);
        assert_eq!(p.line_pos, 7);
        assert_eq!(p.end_line, 2);
        assert_eq!(p.end_line_pos, 1);
        assert_eq!(p.before, "before ");
        assert_eq!(p.after, " after");
    }

    #[test]
    fn many_matches_are_collected_without_prefix_rescans() {
        let content = "127.0.0.1 example.test\n".repeat(10_000);
        let positions = find_positions_in_content(&content, &re("127"));
        assert_eq!(positions.len(), 10_000);
        assert_eq!(positions[9_999].line, 10_000);
        assert_eq!(positions[9_999].line_pos, 0);
    }

    #[test]
    fn replace_all_treats_replacement_as_literal_text() {
        let (content, count) = replace_all_in_content("one 123 two 456", &re(r"\d+"), "$1");
        assert_eq!(count, 2);
        assert_eq!(content, "one $1 two $1");
    }

    #[test]
    fn replace_one_uses_utf16_offsets() {
        let state = temp_state("replace-one");
        let manifest = Manifest {
            root: vec![json!({
                "id": "local-one",
                "title": "Local",
                "type": "local",
            })],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        entries::write_entry(&state.paths.entries_dir, "local-one", "前缀😀match tail").unwrap();

        let replaced = replace_one_in_manifest(
            &state,
            FindReplaceOneArgs {
                item_id: "local-one".into(),
                start: 4,
                end: 9,
                expected: "match".into(),
                replace_to: "done".into(),
            },
        )
        .unwrap();

        assert!(replaced);
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "local-one").unwrap(),
            "前缀😀done tail"
        );
    }

    #[test]
    fn replace_one_treats_missing_type_as_local() {
        let state = temp_state("replace-one-missing-type");
        let manifest = Manifest {
            root: vec![json!({
                "id": "local-one",
                "title": "Local",
            })],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        entries::write_entry(&state.paths.entries_dir, "local-one", "foo local").unwrap();

        let replaced = replace_one_in_manifest(
            &state,
            FindReplaceOneArgs {
                item_id: "local-one".into(),
                start: 0,
                end: 3,
                expected: "foo".into(),
                replace_to: "bar".into(),
            },
        )
        .unwrap();

        assert!(replaced);
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "local-one").unwrap(),
            "bar local"
        );
    }

    #[test]
    fn replace_one_skips_remote_items() {
        let state = temp_state("replace-one-remote");
        let manifest = Manifest {
            root: vec![json!({
                "id": "remote-one",
                "title": "Remote",
                "type": "remote",
            })],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        entries::write_entry(&state.paths.entries_dir, "remote-one", "foo remote").unwrap();

        let replaced = replace_one_in_manifest(
            &state,
            FindReplaceOneArgs {
                item_id: "remote-one".into(),
                start: 0,
                end: 3,
                expected: "foo".into(),
                replace_to: "bar".into(),
            },
        )
        .unwrap();

        assert!(!replaced);
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "remote-one").unwrap(),
            "foo remote"
        );
    }

    #[test]
    fn replace_one_returns_false_when_expected_text_changed() {
        let state = temp_state("replace-one-stale");
        let manifest = Manifest {
            root: vec![json!({
                "id": "local-one",
                "title": "Local",
                "type": "local",
            })],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        entries::write_entry(&state.paths.entries_dir, "local-one", "foo local").unwrap();

        let replaced = replace_one_in_manifest(
            &state,
            FindReplaceOneArgs {
                item_id: "local-one".into(),
                start: 0,
                end: 3,
                expected: "bar".into(),
                replace_to: "baz".into(),
            },
        )
        .unwrap();

        assert!(!replaced);
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "local-one").unwrap(),
            "foo local"
        );
    }

    #[test]
    fn replace_all_skips_remote_items() {
        let state = temp_state("replace-all-remote");
        let manifest = Manifest {
            root: vec![
                json!({
                    "id": "local-one",
                    "title": "Local",
                    "type": "local",
                }),
                json!({
                    "id": "remote-one",
                    "title": "Remote",
                    "type": "remote",
                }),
            ],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        entries::write_entry(&state.paths.entries_dir, "local-one", "foo local").unwrap();
        entries::write_entry(&state.paths.entries_dir, "remote-one", "foo remote").unwrap();

        let outcome =
            replace_all_in_manifest(&state, "foo", &FindOptions::default(), "bar").unwrap();

        assert_eq!(outcome.item_ids, vec!["local-one"]);
        assert_eq!(outcome.replaced_count, 1);
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "local-one").unwrap(),
            "bar local"
        );
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "remote-one").unwrap(),
            "foo remote"
        );
    }

    #[test]
    fn replace_all_reports_local_read_errors() {
        let state = temp_state("replace-all-read-error");
        let manifest = Manifest {
            root: vec![json!({
                "id": "bad/id",
                "title": "Bad",
                "type": "local",
            })],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();

        let error = replace_all_in_manifest(&state, "foo", &FindOptions::default(), "bar")
            .expect_err("invalid local entry id should fail replace all");

        assert!(error.contains("bad/id"));
    }

    #[test]
    fn replace_all_does_not_write_before_read_preflight_succeeds() {
        let state = temp_state("replace-all-read-error-preflight");
        let manifest = Manifest {
            root: vec![
                json!({
                    "id": "local-one",
                    "title": "Local",
                    "type": "local",
                }),
                json!({
                    "id": "bad/id",
                    "title": "Bad",
                    "type": "local",
                }),
            ],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        entries::write_entry(&state.paths.entries_dir, "local-one", "foo local").unwrap();

        let error = replace_all_in_manifest(&state, "foo", &FindOptions::default(), "bar")
            .expect_err("invalid later local entry id should fail replace all");

        assert!(error.contains("bad/id"));
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "local-one").unwrap(),
            "foo local"
        );
    }

    #[test]
    fn saved_bom_keeps_find_and_replace_offsets_aligned_with_open_editor() {
        let state = temp_state("find-bom");
        let manifest = Manifest {
            root: vec![json!({"id": "local-one", "title": "Local", "type": "local"})],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        let text = "\u{feff}127.0.0.1 target.test\n";
        // Pasting a BOM into an open editor preserves it in the document. A
        // save must not silently remove it only from the backend's text.
        entries::write_entry(&state.paths.entries_dir, "local-one", text).unwrap();
        let found = find_in_manifest(&state, "target", &FindOptions::default()).unwrap();
        let position = &found[0].positions[0];
        assert_eq!(position.start, 11);
        assert_eq!(position.end, 17);
        assert!(replace_one_in_manifest(
            &state,
            FindReplaceOneArgs {
                item_id: "local-one".into(),
                start: 11,
                end: 17,
                expected: "target".into(),
                replace_to: "updated".into(),
            }
        )
        .unwrap());
        assert_eq!(
            entries::read_entry(&state.paths.entries_dir, "local-one").unwrap(),
            "\u{feff}127.0.0.1 updated.test\n"
        );
    }

    #[test]
    fn find_offsets_match_lf_view_when_disk_has_crlf() {
        // Regression for plan.md §1: a v4-migrated or hand-written
        // entry file may still hold CRLF on disk. The renderer feeds
        // CodeMirror an LF-normalized view, so find_in_manifest must
        // report UTF-16 offsets against that same view — otherwise
        // selections drift by one column per preceding CRLF.
        let state = temp_state("find-crlf");
        let manifest = Manifest {
            root: vec![json!({
                "id": "local-one",
                "title": "Local",
                "type": "local",
            })],
            ..Manifest::default()
        };
        manifest.save(&state.paths).unwrap();
        // Bypass write_entry so the on-disk bytes really are CRLF; we
        // want to exercise read_entry's normalization on the read path.
        let path = entries::entry_path(&state.paths.entries_dir, "local-one").unwrap();
        std::fs::write(&path, b"foo\r\nbar\r\nbaz").unwrap();

        let result = find_in_manifest(&state, "bar", &FindOptions::default()).unwrap();

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].positions.len(), 1);
        let p = &result[0].positions[0];
        // LF view: "foo\n" is 4 UTF-16 units. With raw CRLF the offset
        // would be 5 and the renderer's selection would be off by one.
        assert_eq!(p.start, 4);
        assert_eq!(p.end, 7);
        assert_eq!(p.line, 2);
        assert_eq!(p.line_pos, 0);
    }
}
