#!/bin/bash
# Builds, signs and installs Switch Kho into ~/Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

scripts/build-app.sh
pkill -x SwitchKho || true
rm -rf "$HOME/Applications/Switch Kho.app"
mkdir -p "$HOME/Applications"
cp -R "build/Switch Kho.app" "$HOME/Applications/"
echo "Đã cài: $HOME/Applications/Switch Kho.app"
