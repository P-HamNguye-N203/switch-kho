#!/bin/bash
# Builds a release binary and wraps it in "build/Switch Kho.app", signed with
# the "Switch Kho Local" identity from the dedicated signing keychain.
# Exit code 2 means the signing keychain is locked.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=toolchain.sh
source scripts/toolchain.sh

KC="$HOME/Library/Keychains/switchkho-signing.keychain-db"
APP="build/Switch Kho.app"

# --test-sessions: an acceptance build that also accepts --data-dir for separate test sessions.
EXTRA=()
if [ "${1:-}" = "--test-sessions" ]; then EXTRA=(-Xswiftc -DSWITCHKHO_TEST_SESSIONS); fi
"$SWIFT_BIN" build -c release ${EXTRA[@]+"${EXTRA[@]}"}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SwitchKho "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Unlock with the password kept in the login keychain, when the signing keychain was
# created with --auto.
if pw="$(security find-generic-password -s switchkho-signing -a "$USER" -w 2>/dev/null)"; then
    security unlock-keychain -p "$pw" "$KC" 2>/dev/null || true
    unset pw
fi

set +e
sign_output="$(codesign --force --options runtime --timestamp=none \
    --keychain "$KC" -s "Switch Kho Local" "$APP" 2>&1)"
sign_status=$?
set -e

if [ "$sign_status" -ne 0 ]; then
    echo "$sign_output"
    if echo "$sign_output" | grep -Eq "User interaction is not allowed|errSecInternalComponent"; then
        echo "Keychain ký đang khoá. Hãy chạy trong Terminal: security unlock-keychain ~/Library/Keychains/switchkho-signing.keychain-db"
        exit 2
    fi
    exit "$sign_status"
fi

echo "Đã ký: $APP"
