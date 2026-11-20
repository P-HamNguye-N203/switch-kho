#!/bin/bash
# Works around a broken SwiftPM in Command Line Tools without sudo: clones
# /Library/Developer/CommandLineTools into ~/Library/Developer/SwitchKhoCLT
# (APFS clone, no extra space) and removes the stale *.private.swiftinterface
# files that break Package.swift compilation. Safe to re-run.
set -euo pipefail

SRC="/Library/Developer/CommandLineTools"
DST="$HOME/Library/Developer/SwitchKhoCLT"

rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -Rc "$SRC" "$DST"
find "$DST/usr/lib/swift/pm" -maxdepth 3 -name "*.private.swiftinterface" -delete
pkgutil --pkg-info com.apple.pkg.CLTools_Executables | awk '/^version:/{print $2}' > "$DST/.switchkho-clt-version"
echo "Bộ công cụ cục bộ: $DST"
