#!/bin/bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon/switch-kho-icon.svg.
# Needs rsvg-convert (brew install librsvg); the built .icns is committed, so a
# normal build does not need it.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set="$work/AppIcon.iconset"
mkdir "$set"
for z in 16 32 128 256 512; do
    rsvg-convert -w "$z" Resources/AppIcon/switch-kho-icon.svg -o "$set/icon_${z}x${z}.png"
    rsvg-convert -w $((z * 2)) Resources/AppIcon/switch-kho-icon.svg -o "$set/icon_${z}x${z}@2x.png"
done
iconutil -c icns "$set" -o Resources/AppIcon.icns
echo "Đã tạo Resources/AppIcon.icns"
