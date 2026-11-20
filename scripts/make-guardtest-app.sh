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
  pkill -f "SwitchKhoGuardTest.app/Contents/MacOS/guardtest" || true
  rm -rf "$app"
  # Never delete through a Switch Kho link; that must be brought back first.
  if [[ -L "$data" ]]; then echo "Dữ liệu vẫn là liên kết Kho — hãy 'Đưa về máy' trước" >&2; exit 1; fi
  rm -rf "$data"
  echo "Đã xoá app giả và dữ liệu"
  exit 0
fi

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
printf 'import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.regular)\napp.run()\n' > "$src"
SDKROOT="$SDKROOT" "${SWIFT_BIN%swift}swiftc" -o "$app/Contents/MacOS/guardtest" "$src"
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "dữ liệu thử $(date)" > "$data/data.txt"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Đã tạo $app"
