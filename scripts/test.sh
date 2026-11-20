#!/bin/bash
# Runs the KhoCore test suite. Fails when no test actually ran, so that a
# filtered run matching nothing can never pass silently.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=toolchain.sh
source scripts/toolchain.sh

out="${TMPDIR:-/tmp}/switchkho-test-last.txt"

# Sandboxes left behind by a crashed run (they can hold multi-GB sparse files).
find "${TMPDIR:-/tmp}" -maxdepth 1 -name "switchkho-tests-*" -mmin +60 -print0 2>/dev/null |
    while IFS= read -r -d '' d; do chflags -R nouchg "$d" 2>/dev/null; rm -rf "$d"; done

set +e
"$SWIFT_BIN" test "${TEST_FLAGS[@]}" "$@" 2>&1 | tee "$out"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
    exit "$status"
fi

if ! grep -Eq "Test run with [1-9][0-9]* tests?" "$out"; then
    echo "Không có test nào chạy"
    exit 1
fi

if [ "${SWITCHKHO_REAL_KHO:-}" = "1" ] && grep -q "skipped" "$out"; then
    echo "Test Kho thật bị bỏ qua"
    exit 1
fi
