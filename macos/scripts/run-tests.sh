#!/usr/bin/env bash
# Runs every automated suite for the native rewrite: the Rust core, the FFI, the
# Tauri host library, and the Swift bridge and UI-model tests. Nothing here
# writes the real /etc/hosts; the Swift and Rust tests use temporary data roots.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

# The whole file is compared, not a marker count (append mode rewrites inside
# the block), and the check runs even when a suite fails.
before="$(shasum -a 256 /etc/hosts)"
check_hosts() {
  status=$?
  if [ "$(shasum -a 256 /etc/hosts)" != "$before" ]; then
    echo "error: /etc/hosts changed during the tests" >&2
    exit 1
  fi
  echo "/etc/hosts unchanged"
  exit "$status"
}
trap check_hosts EXIT

cargo test --manifest-path "$repo_root/crates/swh-core/Cargo.toml"
cargo test --manifest-path "$repo_root/crates/swh-ffi/Cargo.toml"
cargo test --manifest-path "$repo_root/src-tauri/Cargo.toml" --lib

"$repo_root/macos/scripts/build-core.sh"
(cd "$repo_root/macos/SwitchHostsNative" && swift test)
