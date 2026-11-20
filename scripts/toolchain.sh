#!/bin/bash
# Sourced by the other scripts. Selects the Swift toolchain:
# - a user-local clone of Command Line Tools at ~/Library/Developer/SwitchKhoCLT
#   (created by scripts/make-local-toolchain.sh, with the stale
#   *.private.swiftinterface files removed) when it exists;
# - otherwise the system `swift`.
# Exposes SWIFT_BIN and TEST_FLAGS (flags that make `import Testing` work with
# Command Line Tools).

CLT_CLONE="$HOME/Library/Developer/SwitchKhoCLT"

if [ -x "$CLT_CLONE/usr/bin/swift" ]; then
    SWIFT_BIN="$CLT_CLONE/usr/bin/swift"
    CLT_ROOT="$CLT_CLONE"
    export SDKROOT="$CLT_CLONE/SDKs/MacOSX.sdk"
    stamp="$(cat "$CLT_CLONE/.switchkho-clt-version" 2>/dev/null || true)"
    current="$(pkgutil --pkg-info com.apple.pkg.CLTools_Executables 2>/dev/null | awk '/^version:/{print $2}')"
    if [ -n "$current" ] && [ "$stamp" != "$current" ]; then
        echo "Cảnh báo: Command Line Tools đã đổi phiên bản ($stamp → $current). Chạy lại scripts/make-local-toolchain.sh và xoá .build/." >&2
    fi
    echo "Toolchain: bản sao cục bộ $CLT_CLONE" >&2
else
    SWIFT_BIN="swift"
    CLT_ROOT="/Library/Developer/CommandLineTools"
    echo "Toolchain: swift của hệ thống" >&2
fi

TEST_FLAGS=(
    -Xswiftc "-F$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/usr/lib"
)
