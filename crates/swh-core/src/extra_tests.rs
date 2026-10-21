//! Tests the fork adds for upstream modules. The modules themselves are
//! compiled in place from `src-tauri/src` and stay untouched, so their extra
//! coverage lives here (tracked in `crates/upstream-sync.txt`).

/// The remote-hosts client routes through the configured proxy. The proxies
/// here are plain TCP servers, so the tests see exactly what goes over the wire.
mod proxy_routing_tests {
    use crate::http::build_client;
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

mod config_tests {
    use crate::storage::AppConfig;
    use serde_json::json;

    #[test]
    fn apply_partial_sets_and_clears_the_locale() {
        let mut cfg = AppConfig::default();

        cfg.apply_partial(&json!({ "locale": "zh_CN" })).unwrap();
        assert_eq!(cfg.locale.as_deref(), Some("zh_CN"));

        cfg.apply_partial(&json!({ "locale": null })).unwrap();
        assert_eq!(cfg.locale, None, "null means follow the system language");
    }
}
