#!/usr/bin/env bash
# Builds ~/Applications/SwitchKhoGuardTest.app, a real (do-nothing) Cocoa app with data in
# ~/Library/Application Support/SwitchKhoGuardTest, to try the Kho guard without real apps.
# Remove with: scripts/make-guardtest-app.sh --remove
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/toolchain.sh"
app="$HOME/Applications/SwitchKhoGuardTest.app"
data="$HOME/Library/Application Support/SwitchKhoGuardTest"

if [[ "${1:-}" == "--remove" ]]; then
  # Never delete through a Switch Kho link; that must be brought back first.
  if [[ -L "$data" ]]; then echo "Dữ liệu vẫn là liên kết Kho — hãy 'Đưa về máy' trước" >&2; exit 1; fi
  pkill -f "SwitchKhoGuardTest.app/Contents/MacOS/guardtest" || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
  rm -rf "$app"
  rm -rf "$data"
  echo "Đã xoá app giả và dữ liệu"
  exit 0
fi

# Re-running after "Chạy từ Kho" would write through the link onto the Kho.
if [[ -L "$data" ]]; then echo "Dữ liệu đang là liên kết Kho — không tạo lại" >&2; exit 1; fi
mkdir -p "$app/Contents/MacOS" "$data"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.switchkho.guardtest</string>
  <key>CFBundleName</key><string>SwitchKhoGuardTest</string>
  <key>CFBundleExecutable</key><string>guardtest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
src="$(mktemp -d)/main.swift"
# Keeps its data file open, like a real app, so the Kho cannot be ejected while it runs.
cat > "$src" <<'SWIFT'
import AppKit
let data = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/SwitchKhoGuardTest/data.txt")
let handle = try? FileHandle(forReadingFrom: data)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.run()
_ = handle
SWIFT
SDKROOT="${SDKROOT:-}" "${SWIFT_BIN%swift}swiftc" -o "$app/Contents/MacOS/guardtest" "$src"
codesign --force --sign - "$app"
codesign -dv "$app" 2>&1 | grep -E "^(Identifier|Signature)" || true
echo "dữ liệu thử $(date)" > "$data/data.txt"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Đã tạo $app"
