//! C ABI over `swh-core` for the native macOS app. The contract is in
//! `include/swh.h`; the points below are the parts a caller must respect.
//!
//! - `swh_open` returns a handle. `swh_close` frees it. Do not call
//!   `swh_close` while another thread is inside `swh_invoke` on that handle.
//! - `swh_invoke` returns a heap JSON envelope, `{"ok":true,"value":...}` or
//!   `{"ok":false,"error":"..."}`. Free it with `swh_free_string`.
//! - Events arrive on arbitrary threads through the callback given to
//!   `swh_open`. The pointers are valid only for the duration of the call.
//! - Every entry point catches panics. Unwinding into C is undefined
//!   behaviour, so a panic becomes an error envelope instead.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};
use swh_core::api;
use swh_core::events::EventSink;
use swh_core::http_api::{HttpApi, HttpContext, NoRenderer};
use swh_core::import_export::preview::Sessions;
use swh_core::refresh;
use swh_core::storage::{paths::V5Paths, AppState};
use tokio::runtime::Runtime;

/// Receives `(user, event_name, payload_json)`. Runs on any thread.
pub type SwhEventCallback =
    Option<extern "C" fn(user: *mut c_void, event: *const c_char, payload_json: *const c_char)>;

/// Opaque to C. One per open data root.
pub struct SwhHandle {
    runtime: Runtime,
    state: Arc<AppState>,
    events: Arc<CallbackSink>,
    /// Ends the background refresh scanner on its next tick.
    scanner_stop: Arc<AtomicBool>,
    http: HttpApi,
    imports: Sessions,
}

struct CallbackSink {
    callback: SwhEventCallback,
    user: *mut c_void,
}

// SAFETY: the host promises that `user` may be used from any thread (see
// `swh.h`). The raw pointer is never dereferenced by Rust, only passed back.
unsafe impl Send for CallbackSink {}
unsafe impl Sync for CallbackSink {}

impl EventSink for CallbackSink {
    fn emit(&self, event: &str, payload: Value) {
        let Some(callback) = self.callback else {
            return;
        };
        // JSON never contains a raw NUL, so these conversions only fail for a
        // malformed event name, which the core never produces.
        let (Ok(name), Ok(body)) = (CString::new(event), CString::new(payload.to_string())) else {
            return;
        };
        let _ = catch_unwind(AssertUnwindSafe(|| {
            callback(self.user, name.as_ptr(), body.as_ptr());
        }));
    }
}

/// Open the hosts data at `root`, or the default root when `root` is NULL.
///
/// Returns NULL on failure and writes a message to `error_out` if it is
/// non-NULL. Free that message with `swh_free_string`.
///
/// # Safety
/// `root` must be NULL or a valid NUL-terminated string. `error_out` must be
/// NULL or point to writable storage for one pointer.
#[no_mangle]
pub unsafe extern "C" fn swh_open(
    root: *const c_char,
    callback: SwhEventCallback,
    user: *mut c_void,
    error_out: *mut *mut c_char,
) -> *mut SwhHandle {
    let opened = catch_unwind(AssertUnwindSafe(|| open_inner(root, callback, user)));
    match opened {
        Ok(Ok(handle)) => Box::into_raw(Box::new(handle)),
        Ok(Err(message)) => {
            write_error(error_out, &message);
            ptr::null_mut()
        }
        Err(_) => {
            write_error(error_out, "panic while opening the data directory");
            ptr::null_mut()
        }
    }
}

/// Free a handle returned by `swh_open`. NULL is a no-op.
///
/// # Safety
/// `handle` must be NULL or a pointer from `swh_open` that has not been closed.
#[no_mangle]
pub unsafe extern "C" fn swh_close(handle: *mut SwhHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let handle = Box::from_raw(handle);
        handle.scanner_stop.store(true, Ordering::Relaxed);
        drop(handle);
    }));
}

/// Run `command` with the JSON array `args_json` (NULL means no arguments).
/// Returns a heap envelope; free it with `swh_free_string`.
///
/// # Safety
/// `handle` must be a live handle from `swh_open`. `command` must be a valid
/// NUL-terminated string. `args_json` must be NULL or a valid string.
#[no_mangle]
pub unsafe extern "C" fn swh_invoke(
    handle: *const SwhHandle,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let envelope = catch_unwind(AssertUnwindSafe(|| invoke_inner(handle, command, args_json)))
        .unwrap_or_else(|_| error_envelope("internal panic"));
    into_c_string(envelope.to_string())
}

/// Free a string returned by this library. NULL is a no-op.
///
/// # Safety
/// `s` must be NULL or a pointer returned by this library that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn swh_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(s))));
}

// ---- internals -------------------------------------------------------------

fn open_inner(
    root: *const c_char,
    callback: SwhEventCallback,
    user: *mut c_void,
) -> Result<SwhHandle, String> {
    // Two workers are enough: calls are user-driven and the blocking pool
    // handles file and process work. A larger pool would only add memory.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("swh-core")
        .build()
        .map_err(|e| e.to_string())?;

    let state = Arc::new(
        match root_path(root)? {
            Some(path) => AppState::bootstrap_at(V5Paths::under(path), None),
            None => AppState::bootstrap(),
        }
        .map_err(|e| e.to_string())?,
    );
    let events = Arc::new(CallbackSink { callback, user });
    let scanner_stop = Arc::new(AtomicBool::new(false));

    // Same gate as the Tauri host: no background refresh while the data root
    // is in recovery, because it would write into the fallback directory.
    if state.data_dir_recovery.is_none() {
        runtime.spawn(refresh::run_background_scanner(
            state.clone(),
            events.clone(),
            scanner_stop.clone(),
        ));
    }

    // The local HTTP API follows the saved preference, as in the Tauri app.
    let http = HttpApi::new();
    if state.data_dir_recovery.is_none() {
        let config = state.config.lock().expect("config mutex poisoned").clone();
        if config.http_api_on {
            let ctx = HttpContext {
                state: state.clone(),
                events: events.clone(),
                host: Arc::new(NoRenderer),
            };
            if let Err(error) = http.configure(runtime.handle(), ctx, &config, || Ok(())) {
                log::warn!("http_api startup failed: {error}");
            }
        }
    }

    Ok(SwhHandle {
        runtime,
        state,
        events,
        scanner_stop,
        http,
        imports: Sessions::default(),
    })
}

fn root_path(root: *const c_char) -> Result<Option<PathBuf>, String> {
    if root.is_null() {
        return Ok(None);
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string.
    let text = unsafe { CStr::from_ptr(root) }
        .to_str()
        .map_err(|_| "data root is not valid UTF-8".to_string())?;
    Ok(Some(PathBuf::from(text)))
}

fn invoke_inner(handle: *const SwhHandle, command: *const c_char, args_json: *const c_char) -> Value {
    if handle.is_null() {
        return error_envelope("null handle");
    }
    if command.is_null() {
        return error_envelope("null command");
    }
    // SAFETY: the caller guarantees `handle` is live and `command` is a valid string.
    let handle = unsafe { &*handle };
    let command = match unsafe { CStr::from_ptr(command) }.to_str() {
        Ok(text) => text,
        Err(_) => return error_envelope("command is not valid UTF-8"),
    };
    let args = match parse_args(args_json) {
        Ok(args) => args,
        Err(message) => return error_envelope(&message),
    };

    // The listener is managed here rather than in `api::dispatch`: changing it
    // can block until the old socket closes, so it must run outside the runtime.
    let result = match command {
        "http_api_status" => Ok(json!(handle.http.status())),
        "http_api_configure" => http_api_configure(handle, &args),
        _ => handle.runtime.block_on(api::dispatch(
            &handle.state,
            handle.events.as_ref(),
            &handle.imports,
            command,
            args,
        )),
    };
    match result {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(message) => error_envelope(&message),
    }
}

/// `http_api_configure(on, port, only_local)`. Reserves the listener, then
/// saves the preference and publishes it, as upstream's config commit does:
/// a failure leaves both the listener and the saved config as they were.
fn http_api_configure(handle: &SwhHandle, args: &[Value]) -> Result<Value, String> {
    let on = args.first().and_then(Value::as_bool).ok_or("http_api_configure: args[0] must be a boolean")?;
    let patch = json!({
        "http_api_on": on,
        "http_api_port": args.get(1).cloned().unwrap_or(Value::Null),
        "http_api_only_local": args.get(2).and_then(Value::as_bool).unwrap_or(true),
    });
    handle.state.require_data_dir_usable().map_err(|e| e.to_string())?;
    let _write = handle.state.config_write_lock.lock().expect("config write mutex poisoned");
    let mut next = handle.state.config.lock().expect("config mutex poisoned").clone();
    next.apply_partial(&patch).map_err(|e| e.to_string())?;

    let ctx = HttpContext {
        state: handle.state.clone(),
        events: handle.events.clone(),
        host: Arc::new(NoRenderer),
    };
    let persist = || api::save_and_publish_config(&handle.state, next.clone());
    handle
        .http
        .configure(handle.runtime.handle(), ctx, &next, persist)
        .map_err(|e| e.to_string())?;
    Ok(json!(handle.http.status()))
}

fn parse_args(args_json: *const c_char) -> Result<Vec<Value>, String> {
    if args_json.is_null() {
        return Ok(Vec::new());
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string.
    let text = unsafe { CStr::from_ptr(args_json) }
        .to_str()
        .map_err(|_| "arguments are not valid UTF-8".to_string())?;
    match serde_json::from_str::<Value>(text).map_err(|e| format!("invalid arguments JSON: {e}"))? {
        Value::Array(items) => Ok(items),
        Value::Null => Ok(Vec::new()),
        _ => Err("arguments must be a JSON array".to_string()),
    }
}

fn error_envelope(message: &str) -> Value {
    json!({ "ok": false, "error": message })
}

fn into_c_string(text: String) -> *mut c_char {
    // The envelope is built from serde_json, which escapes NUL, so this only
    // fails if something upstream breaks that guarantee. Return an error
    // rather than a NULL the caller would not expect.
    match CString::new(text) {
        Ok(s) => s.into_raw(),
        Err(_) => CString::new(error_envelope("response contained NUL").to_string())
            .expect("static error envelope has no NUL")
            .into_raw(),
    }
}

fn write_error(error_out: *mut *mut c_char, message: &str) {
    if error_out.is_null() {
        return;
    }
    let text = CString::new(message).unwrap_or_else(|_| CString::new("error").expect("no NUL"));
    // SAFETY: the caller guarantees `error_out` is writable when non-NULL.
    unsafe { *error_out = text.into_raw() };
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::ffi::CString;
    use std::sync::Mutex;

    fn temp_root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "swh-ffi-test-{}-{}-{name}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn call(handle: *const SwhHandle, command: &str, args: &str) -> Value {
        let command = CString::new(command).unwrap();
        let args = CString::new(args).unwrap();
        let raw = unsafe { swh_invoke(handle, command.as_ptr(), args.as_ptr()) };
        let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_string();
        unsafe { swh_free_string(raw) };
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn round_trips_a_list_through_the_c_api() {
        let root = temp_root("roundtrip");
        let root_c = CString::new(root.to_str().unwrap()).unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let handle = unsafe { swh_open(root_c.as_ptr(), None, ptr::null_mut(), &mut error) };
        assert!(!handle.is_null(), "open failed");

        let list = r#"[[{"id":"a","title":"A","type":"local","on":false}]]"#;
        let saved = call(handle, "set_list", list);
        assert_eq!(saved["ok"], json!(true), "{saved}");

        let read = call(handle, "get_list", "[]");
        assert_eq!(read["value"][0]["id"], json!("a"));

        unsafe { swh_close(handle as *mut SwhHandle) };
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn unknown_command_and_bad_arguments_return_error_envelopes() {
        let root = temp_root("errors");
        let root_c = CString::new(root.to_str().unwrap()).unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let handle = unsafe { swh_open(root_c.as_ptr(), None, ptr::null_mut(), &mut error) };
        assert!(!handle.is_null());

        let unknown = call(handle, "no_such_command", "[]");
        assert_eq!(unknown["ok"], json!(false));
        assert!(unknown["error"].as_str().unwrap().contains("unknown command"));

        let not_array = call(handle, "get_list", "{}");
        assert_eq!(not_array["ok"], json!(false));

        unsafe { swh_close(handle as *mut SwhHandle) };
        let _ = std::fs::remove_dir_all(root);
    }

    extern "C" fn record_event(user: *mut c_void, event: *const c_char, _payload: *const c_char) {
        let events = unsafe { &*(user as *const Mutex<Vec<String>>) };
        let name = unsafe { CStr::from_ptr(event) }.to_string_lossy().into_owned();
        events.lock().unwrap().push(name);
    }

    #[test]
    fn refreshes_a_remote_entry_from_a_file_source_and_emits_its_event() {
        let root = temp_root("refresh");
        let source = root.join("source.hosts");
        std::fs::write(&source, "10.0.0.1 remote.example.test\n").unwrap();
        let url = format!("file://{}", source.display());

        let received: Mutex<Vec<String>> = Mutex::new(Vec::new());
        let root_c = CString::new(root.to_str().unwrap()).unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let handle = unsafe {
            swh_open(
                root_c.as_ptr(),
                Some(record_event),
                &received as *const Mutex<Vec<String>> as *mut c_void,
                &mut error,
            )
        };
        assert!(!handle.is_null(), "open failed");

        let tree = json!([[{"id": "r1", "title": "Remote", "type": "remote", "on": false, "url": url}]]);
        let saved = call(handle, "set_list", &tree.to_string());
        assert_eq!(saved["ok"], json!(true), "{saved}");

        let refreshed = call(handle, "refresh_remote_hosts", r#"["r1"]"#);
        assert_eq!(refreshed["ok"], json!(true), "{refreshed}");
        assert_eq!(refreshed["value"]["success"], json!(true), "{refreshed}");

        let content = call(handle, "get_hosts_content", r#"["r1"]"#);
        assert_eq!(content["value"], json!("10.0.0.1 remote.example.test\n"));

        let events = received.lock().unwrap().clone();
        assert!(events.iter().any(|e| e == "hosts_content_changed"), "events: {events:?}");

        unsafe { swh_close(handle as *mut SwhHandle) };
        let _ = std::fs::remove_dir_all(root);
    }

    fn http_get(port: u16, path: &str) -> String {
        use std::io::{Read, Write};
        use std::net::TcpStream;

        let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("listener is up");
        let request = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        response
    }

    #[test]
    fn local_http_api_serves_routes_and_follows_the_saved_preference() {
        use std::io::{Read, Write};
        use std::net::{TcpListener, TcpStream};

        let root = temp_root("http");
        // An empty write mode makes toggles stop before they touch /etc/hosts.
        std::fs::create_dir_all(root.join("internal")).unwrap();
        std::fs::write(root.join("internal/config.json"), r#"{"write_mode": ""}"#).unwrap();
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let root_c = CString::new(root.to_str().unwrap()).unwrap();
        let mut error: *mut c_char = ptr::null_mut();
        let handle = unsafe { swh_open(root_c.as_ptr(), None, ptr::null_mut(), &mut error) };
        assert!(!handle.is_null(), "open failed");
        let saved = call(
            handle,
            "set_list",
            r#"[[{"id":"a","title":"A","type":"local","on":false}]]"#,
        );
        assert_eq!(saved["ok"], json!(true), "{saved}");

        // Port 0 would bind a random port; the config's own check refuses it.
        let zero = call(handle, "http_api_configure", "[true, 0, true]");
        assert_eq!(zero["ok"], json!(false), "{zero}");

        let on = call(handle, "http_api_configure", &format!("[true, {port}, true]"));
        assert_eq!(on["ok"], json!(true), "{on}");
        assert_eq!(on["value"]["running"], json!(true), "{on}");

        let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("listener is up");
        stream
            .write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            .unwrap();
        let mut body = String::new();
        stream.read_to_string(&mut body).unwrap();
        assert!(body.ends_with("Hello SwitchHosts!"), "{body}");

        // Alfred calls these two routes: the list (JSON) and the toggle (terse text).
        let list = http_get(port, "/api/list");
        let list_json: Value = serde_json::from_str(list.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(list_json["success"], json!(true), "{list}");
        assert_eq!(list_json["data"][0]["id"], json!("a"));
        let toggle = http_get(port, "/api/toggle?id=a");
        assert!(toggle.ends_with("write mode not set."), "{toggle}");

        let off = call(handle, "http_api_configure", "[false, 50761, true]");
        assert_eq!(off["value"]["running"], json!(false), "{off}");
        assert!(TcpStream::connect(("127.0.0.1", port)).is_err(), "listener should be closed");

        let status = call(handle, "http_api_status", "[]");
        assert_eq!(status["value"]["running"], json!(false));

        unsafe { swh_close(handle as *mut SwhHandle) };
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn null_handle_is_reported_not_dereferenced() {
        let command = CString::new("get_list").unwrap();
        let raw = unsafe { swh_invoke(ptr::null(), command.as_ptr(), ptr::null()) };
        let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_string();
        unsafe { swh_free_string(raw) };
        assert!(text.contains("null handle"));
    }
}
