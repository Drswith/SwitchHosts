#!/usr/bin/env bash
# Lists strings in the Swift sources that have no Chinese text. The compiler
# writes every localizable key it sees (-emit-localized-strings) into a
# throwaway build folder, and sync-localizations.py compares them with the
# generated zh-Hans Localizable.strings. Run sync-localizations.py first.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT

(cd "$repo_root/macos/SwitchHostsNative" && swift build --build-path "$build" --target SwitchHostsNative \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$build/strings" >/dev/null)
python3 "$repo_root/macos/scripts/sync-localizations.py" --check "$build"
