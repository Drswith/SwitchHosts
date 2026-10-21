#!/usr/bin/env bash
# Builds the Rust core (crates/swh-ffi) as the static library the Swift package links.
# rustup takes the toolchain from rust-toolchain.toml at the repository root
# (stable; the crates need >= 1.90).
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# Match the Swift package's deployment target so the archive does not carry
# objects built for a newer macOS than the app supports.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
cargo build --manifest-path "$repo_root/crates/swh-ffi/Cargo.toml" --release
