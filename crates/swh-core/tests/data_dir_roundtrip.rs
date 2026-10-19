//! Changing the data folder end to end: copy to a new folder, reopen the core
//! the way the app does at launch, then reset to the default location.
//!
//! This test changes HOME for its whole process, so it lives in its own test
//! binary. The pointer file is written under that temporary HOME, never under
//! the real one.

use serde_json::json;
use swh_core::api;
use swh_core::storage::{data_dir_pointer, AppState};

#[test]
fn copy_restart_and_reset_round_trip() {
    let base = std::env::temp_dir().join(format!("swh-datadir-e2e-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let home = base.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: this binary runs a single test, so nothing reads HOME concurrently.
    unsafe { std::env::set_var("HOME", &home) };

    // Launch 1: the default location, with one entry in it.
    let first = AppState::bootstrap().expect("bootstrap on the default location");
    assert_eq!(first.paths.root, home.join(".SwitchHosts"));
    let events = swh_core::events::NoopEvents;
    let sessions = swh_core::import_export::preview::Sessions::default();
    let tree = json!([{ "id": "dev", "type": "local", "title": "Dev", "on": false }]);
    futures_block(api::dispatch(&first, &events, &sessions, "set_list", vec![tree]))
        .expect("set_list");
    futures_block(api::dispatch(
        &first,
        &events,
        &sessions,
        "set_hosts_content",
        vec![json!("dev"), json!("10.0.0.1 dev.example.test\n")],
    ))
    .expect("set_hosts_content");

    // Choose a folder: the plan says it is a custom folder and nothing is written yet.
    let chosen = base.join("chosen");
    std::fs::create_dir_all(&chosen).unwrap();
    let plan = api::data_dir_plan(&first, &chosen).unwrap();
    assert_eq!(plan["kind"], json!("custom"));
    assert_eq!(plan["is_same_as_current"], json!(false));
    assert!(!chosen.join("SwitchHosts.data").exists(), "planning writes nothing");

    // Switch with a copy: the data moves into <chosen>/SwitchHosts.data and the pointer records it.
    let applied = api::apply_data_dir(&first, &chosen, true).unwrap();
    assert_eq!(applied["restart"], json!(true));
    let new_root = chosen.join("SwitchHosts.data");
    assert!(new_root.join("manifest.json").exists(), "the manifest was copied");
    assert_eq!(
        std::fs::read_to_string(new_root.join("entries").join("dev.hosts")).unwrap(),
        "10.0.0.1 dev.example.test\n",
        "the entry content was copied"
    );
    match data_dir_pointer::load() {
        data_dir_pointer::PointerState::Recorded(path) => assert_eq!(path, new_root),
        other => panic!("expected the pointer to record the new folder, got {other:?}"),
    }

    // Launch 2: the app opens the recorded folder and shows the copied entry.
    let second = AppState::bootstrap().expect("bootstrap after the switch");
    assert_eq!(second.paths.root, new_root);
    let list = futures_block(api::dispatch(&second, &events, &sessions, "get_list", vec![])).unwrap();
    assert_eq!(list.as_array().unwrap().len(), 1);
    assert_eq!(list[0]["id"], json!("dev"));
    let status = api::data_dir_status(&second).unwrap();
    assert_eq!(status["active_dir"], json!(new_root.display().to_string()));
    assert_eq!(status["can_reset"], json!(true));

    // Reset: the pointer is cleared and the next launch uses the default location again.
    let reset = api::reset_data_dir(&second).unwrap();
    assert_eq!(reset["restart"], json!(true));
    assert!(!data_dir_pointer::pointer_exists());
    let third = AppState::bootstrap().expect("bootstrap after the reset");
    assert_eq!(third.paths.root, home.join(".SwitchHosts"));
    assert!(home.join(".SwitchHosts").join("manifest.json").exists(), "the default data was never touched");

    let _ = std::fs::remove_dir_all(&base);
}

/// The dispatch function is async; the test drives it with a tiny runtime.
fn futures_block<T>(future: impl std::future::Future<Output = Result<T, String>>) -> Result<T, String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(future)
}
