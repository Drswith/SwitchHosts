#!/usr/bin/env bash
# Builds macos/build/SwitchHosts.app: the Rust core, the Swift app, its
# localized strings, and an Info.plist. The bundle identifier differs from the
# Tauri app so both can be installed side by side.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
pkg="$repo_root/macos/SwitchHostsNative"
app="$repo_root/macos/build/SwitchHosts.app"
version="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])))" "$repo_root/src/version.json")"

"$repo_root/macos/scripts/build-core.sh"
(cd "$pkg" && swift build -c release)
bin_dir="$(cd "$pkg" && swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/SwitchHostsNative" "$app/Contents/MacOS/SwitchHosts"

# 5.0.2's app icon and its template tray icon.
cp "$repo_root/src-tauri/icons/icon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$repo_root/src-tauri/icons/tray-mac.png" "$app/Contents/Resources/tray-mac.png"

# Text() looks strings up in the main bundle, so copy the .lproj folders there.
# Copy from the package sources: the SwiftPM bundle can keep folders from older builds.
for lproj in "$pkg"/Sources/SwitchHostsNative/Resources/*.lproj; do
  cp -R "$lproj" "$app/Contents/Resources/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SwitchHosts</string>
  <key>CFBundleDisplayName</key><string>SwitchHosts</string>
  <key>CFBundleIdentifier</key><string>net.oldj.switchhosts.native</string>
  <key>CFBundleExecutable</key><string>SwitchHosts</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string><string>zh-Hans</string>
  </array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with SIGN_IDENTITY when given, else the first local Apple Development
# identity, else ad hoc. Only a Developer ID signature plus notarization can be
# distributed; a development identity runs on this machine only.
identity="${SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" "$app" >/dev/null
  echo "signed with: $identity" >&2
else
  codesign --force --sign - "$app" >/dev/null
  echo "signed ad hoc" >&2
fi
echo "$app"
