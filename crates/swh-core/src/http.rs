//! Shared `reqwest::Client` builder that honours the user's proxy +
//! User-Agent settings.
//!
//! Used by both the remote-hosts refresh path (`refresh::refresh_one`)
//! and the URL-import path (`commands::import_data_from_url`). Keeping
//! the construction in one place means a future tweak — adding TLS
//! options, request signing, retries — only has to land here once,
//! and clears implementation-notes D8 ("`import_data_from_url` does
//! not honour proxy config").

use std::time::Duration;

use crate::storage::{AppConfig, AppState};

mod error;
pub use error::request_error_message;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
pub const MAX_REMOTE_HOSTS_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_IMPORT_BACKUP_BYTES: usize = 64 * 1024 * 1024;
const USER_AGENT: &str = concat!(
    "SwitchHosts/",
    env!("SWH_VERSION"),
    " (Tauri; ",
    env!("CARGO_PKG_NAME"),
    ")"
);

/// Build a fresh `reqwest::Client` configured with:
///
/// - 30s connect+read timeout (matches the Electron `axios` default)
/// - SwitchHosts user agent string
/// - HTTP proxy from `use_proxy` / `proxy_protocol` / `proxy_host` /
///   `proxy_port` config when `use_proxy == true`
///
/// Returns a `String` error so commands can convert it to whatever
/// renderer-facing shape they need.
pub fn build_client(state: &AppState) -> Result<reqwest::Client, String> {
    let mut builder = reqwest::Client::builder()
        .timeout(DEFAULT_TIMEOUT)
        .user_agent(USER_AGENT);

    let proxy_url = configured_proxy_url_from_state(state);

    if let Some(proxy_url) = proxy_url {
        let proxy = reqwest::Proxy::all(&proxy_url).map_err(|_| {
            "Invalid proxy settings. Check the proxy protocol, host and port.".to_string()
        })?;
        builder = builder.proxy(proxy);
    }

    builder.build().map_err(request_error_message)
}

pub async fn response_text_with_limit(
    response: reqwest::Response,
    max_bytes: usize,
) -> Result<String, String> {
    let body = response_bytes_with_limit(response, max_bytes).await?;
    Ok(String::from_utf8_lossy(&body).into_owned())
}

pub async fn response_bytes_with_limit(
    mut response: reqwest::Response,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    if let Some(content_length) = response.content_length() {
        if content_length > max_bytes as u64 {
            return Err(size_limit_message(content_length, max_bytes));
        }
    }

    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(request_error_message)? {
        extend_body_with_limit(&mut body, &chunk, max_bytes)?;
    }

    Ok(body)
}

pub fn read_text_file_with_limit(
    path: &std::path::Path,
    max_bytes: usize,
) -> Result<String, String> {
    let body = read_file_with_limit(path, max_bytes)?;
    Ok(String::from_utf8_lossy(&body).into_owned())
}

pub fn read_file_with_limit(path: &std::path::Path, max_bytes: usize) -> Result<Vec<u8>, String> {
    use std::io::Read;

    let metadata = std::fs::metadata(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    if metadata.len() > max_bytes as u64 {
        return Err(size_limit_message(metadata.len(), max_bytes));
    }

    let file = std::fs::File::open(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let mut limited = file.take(max_bytes as u64 + 1);
    let mut body = Vec::new();
    limited
        .read_to_end(&mut body)
        .map_err(|e| format!("read {}: {e}", path.display()))?;

    if body.len() > max_bytes {
        return Err(size_limit_message(body.len() as u64, max_bytes));
    }

    Ok(body)
}

fn size_limit_message(actual_bytes: u64, max_bytes: usize) -> String {
    format!("response body too large: {actual_bytes} bytes exceeds limit of {max_bytes} bytes")
}

fn extend_body_with_limit(
    body: &mut Vec<u8>,
    chunk: &[u8],
    max_bytes: usize,
) -> Result<(), String> {
    let next_len = body
        .len()
        .checked_add(chunk.len())
        .ok_or_else(|| size_limit_message(u64::MAX, max_bytes))?;
    if next_len > max_bytes {
        return Err(size_limit_message(next_len as u64, max_bytes));
    }
    body.extend_from_slice(chunk);
    Ok(())
}

pub fn configured_proxy_url_from_state(state: &AppState) -> Option<String> {
    let cfg = state.config.lock().expect("config mutex poisoned");
    configured_proxy_url(&cfg)
}

pub(crate) fn configured_proxy_url(cfg: &AppConfig) -> Option<String> {
    let host = cfg.proxy_host.trim();
    if !cfg.use_proxy || host.is_empty() || cfg.proxy_port == 0 {
        return None;
    }

    Some(format!(
        "{}://{}:{}",
        cfg.proxy_protocol, host, cfg.proxy_port
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configured_proxy_url_supports_known_protocols() {
        for (protocol, expected) in [
            ("http", "http://127.0.0.1:1080"),
            ("https", "https://127.0.0.1:1080"),
            ("socks5", "socks5://127.0.0.1:1080"),
        ] {
            let cfg = AppConfig {
                use_proxy: true,
                proxy_protocol: protocol.into(),
                proxy_host: " 127.0.0.1 ".into(),
                proxy_port: 1080,
                ..AppConfig::default()
            };

            assert_eq!(configured_proxy_url(&cfg).as_deref(), Some(expected));
        }
    }

    #[test]
    fn configured_proxy_url_skips_incomplete_settings() {
        let cases = [
            AppConfig {
                use_proxy: false,
                proxy_protocol: "http".into(),
                proxy_host: "127.0.0.1".into(),
                proxy_port: 1080,
                ..AppConfig::default()
            },
            AppConfig {
                use_proxy: true,
                proxy_protocol: "http".into(),
                proxy_host: String::new(),
                proxy_port: 1080,
                ..AppConfig::default()
            },
            AppConfig {
                use_proxy: true,
                proxy_protocol: "http".into(),
                proxy_host: "127.0.0.1".into(),
                proxy_port: 0,
                ..AppConfig::default()
            },
        ];

        for cfg in cases {
            assert_eq!(configured_proxy_url(&cfg), None);
        }
    }

    /// The app and tauri-plugin-updater share reqwest 0.13, so enabling
    /// `socks` on our client also enables it for update downloads.
    #[test]
    fn socks_feature_unified_into_updater_reqwest() {
        let proxy = reqwest::Proxy::all("socks5://127.0.0.1:1080");

        assert!(proxy.is_ok());
    }

    #[test]
    fn extend_body_with_limit_rejects_oversized_chunked_body() {
        let mut body = Vec::new();
        extend_body_with_limit(&mut body, b"abc", 5).unwrap();

        let err = extend_body_with_limit(&mut body, b"def", 5).unwrap_err();

        assert!(err.contains("response body too large"));
        assert_eq!(body, b"abc");
    }

    #[test]
    fn extend_body_with_limit_accepts_body_at_limit() {
        let mut body = Vec::new();
        extend_body_with_limit(&mut body, b"abc", 5).unwrap();
        extend_body_with_limit(&mut body, b"de", 5).unwrap();

        assert_eq!(body, b"abcde");
    }

    #[test]
    fn read_text_file_with_limit_rejects_oversized_files() {
        let path = std::env::temp_dir().join(format!(
            "switchhosts-limited-read-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, b"abcdef").unwrap();

        let err = read_text_file_with_limit(&path, 5).unwrap_err();

        assert!(err.contains("response body too large"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn read_text_file_with_limit_accepts_files_at_limit() {
        let path = std::env::temp_dir().join(format!(
            "switchhosts-limited-read-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, b"abcde").unwrap();

        let text = read_text_file_with_limit(&path, 5).unwrap();

        assert_eq!(text, "abcde");
        let _ = std::fs::remove_file(path);
    }
}

/// The remote-hosts client routes through the configured proxy. The proxies
/// here are plain TCP servers, so the tests see exactly what goes over the wire.
#[cfg(test)]
mod proxy_routing_tests {
    use super::*;
    use crate::storage::{AppState, V5Paths};
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{atomic::AtomicBool, Mutex};

    fn state_with(config: crate::storage::AppConfig) -> AppState {
        let root = std::env::temp_dir().join(format!("swh-proxy-{}-{}", std::process::id(), line!()));
        AppState {
            paths: V5Paths::under(root),
            config: Mutex::new(config),
            store_lock: Mutex::new(()),
            application_recovery: Default::default(),
            config_write_lock: Mutex::new(()),
            update_check_lock: tokio::sync::Mutex::new(()),
            is_will_quit: AtomicBool::new(false),
            last_geometry_persist_ms: std::sync::atomic::AtomicU64::new(0),
            data_dir_recovery: None,
        }
    }

    /// Reads one request head (up to the blank line) and returns its first line.
    fn read_request_line(stream: &mut TcpStream) -> String {
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            if stream.read(&mut byte).unwrap() == 0 {
                break;
            }
            head.push(byte[0]);
        }
        String::from_utf8_lossy(&head).lines().next().unwrap_or_default().to_string()
    }

    fn respond(stream: &mut TcpStream, body: &str) {
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        stream.write_all(response.as_bytes()).unwrap();
    }

    /// An HTTP proxy: answers the first request with `body` and reports its request line.
    fn spawn_http_proxy(body: &'static str) -> (u16, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let line = read_request_line(&mut stream);
            respond(&mut stream, body);
            line
        });
        (port, handle)
    }

    /// A plain origin server that answers one request with `body`.
    fn spawn_origin(body: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_request_line(&mut stream);
            respond(&mut stream, body);
        });
        port
    }

    /// A SOCKS5 proxy without authentication. It accepts one CONNECT, opens the
    /// target, relays the reply, and reports the requested host:port.
    fn spawn_socks5_proxy(origin_port: u16) -> (u16, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut client, _) = listener.accept().unwrap();
            let mut greeting = [0u8; 2];
            client.read_exact(&mut greeting).unwrap();
            let mut methods = vec![0u8; greeting[1] as usize];
            client.read_exact(&mut methods).unwrap();
            client.write_all(&[5, 0]).unwrap();

            let mut request = [0u8; 4];
            client.read_exact(&mut request).unwrap();
            assert_eq!(request[1], 1, "only CONNECT is expected");
            assert_eq!(request[3], 1, "the test targets an IPv4 address");
            let mut ip = [0u8; 4];
            client.read_exact(&mut ip).unwrap();
            let mut port_bytes = [0u8; 2];
            client.read_exact(&mut port_bytes).unwrap();
            let target = format!(
                "{}.{}.{}.{}:{}",
                ip[0], ip[1], ip[2], ip[3],
                u16::from_be_bytes(port_bytes)
            );

            let mut origin = TcpStream::connect(("127.0.0.1", origin_port)).unwrap();
            client.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
            let mut from_client = client.try_clone().unwrap();
            let mut to_origin = origin.try_clone().unwrap();
            std::thread::spawn(move || {
                let _ = std::io::copy(&mut from_client, &mut to_origin);
            });
            let _ = std::io::copy(&mut origin, &mut client);
            target
        });
        (port, handle)
    }

    fn proxy_config(protocol: &str, port: u16) -> crate::storage::AppConfig {
        crate::storage::AppConfig {
            use_proxy: true,
            proxy_protocol: protocol.into(),
            proxy_host: "127.0.0.1".into(),
            proxy_port: port as u32,
            ..crate::storage::AppConfig::default()
        }
    }

    #[tokio::test]
    async fn http_proxy_receives_the_absolute_url() {
        let (proxy_port, seen) = spawn_http_proxy("1.2.3.4 remote.test\n");
        let state = state_with(proxy_config("http", proxy_port));
        let client = build_client(&state).unwrap();

        let body = client.get("http://remote.test/hosts").send().await.unwrap().text().await.unwrap();

        assert_eq!(body, "1.2.3.4 remote.test\n");
        assert_eq!(seen.join().unwrap(), "GET http://remote.test/hosts HTTP/1.1");
    }

    #[tokio::test]
    async fn socks5_proxy_carries_the_request_to_the_origin() {
        let origin_port = spawn_origin("5.6.7.8 origin.test\n");
        let (proxy_port, target) = spawn_socks5_proxy(origin_port);
        let state = state_with(proxy_config("socks5", proxy_port));
        let client = build_client(&state).unwrap();

        let url = format!("http://127.0.0.1:{origin_port}/hosts");
        let body = client.get(&url).send().await.unwrap().text().await.unwrap();

        assert_eq!(body, "5.6.7.8 origin.test\n");
        assert_eq!(target.join().unwrap(), format!("127.0.0.1:{origin_port}"));
    }

    #[tokio::test]
    async fn disabled_proxy_connects_directly() {
        let origin_port = spawn_origin("9.9.9.9 direct.test\n");
        let state = state_with(crate::storage::AppConfig {
            use_proxy: false,
            ..proxy_config("socks5", 1)
        });
        let client = build_client(&state).unwrap();

        let url = format!("http://127.0.0.1:{origin_port}/hosts");
        let body = client.get(&url).send().await.unwrap().text().await.unwrap();

        assert_eq!(body, "9.9.9.9 direct.test\n");
    }
}
