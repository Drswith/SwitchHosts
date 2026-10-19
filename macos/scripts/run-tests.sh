#!/usr/bin/env bash
# Runs every automated suite for the native rewrite: the Rust core, the FFI, the
# Tauri host library, and the Swift bridge and UI-model tests. Nothing here
# writes the real /etc/hosts; the Swift and Rust tests use temporary data roots.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
marker="SWITCHHOSTS_CONTENT_START"

hosts_marker_count() {
  grep -c "$marker" /etc/hosts 2>/dev/null || true
}

before="$(hosts_marker_count)"

cargo test --manifest-path "$repo_root/crates/swh-core/Cargo.toml"
cargo test --manifest-path "$repo_root/crates/swh-ffi/Cargo.toml"
cargo test --manifest-path "$repo_root/src-tauri/Cargo.toml" --lib

"$repo_root/macos/scripts/build-core.sh"
(cd "$repo_root/macos/SwitchHostsNative" && swift test)

after="$(hosts_marker_count)"
echo "managed marker count in /etc/hosts: before=$before after=$after"
if [ "$before" != "$after" ]; then
  echo "error: /etc/hosts changed during the tests" >&2
  exit 1
fi
