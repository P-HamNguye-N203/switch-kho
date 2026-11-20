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
    export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
else
    SWIFT_BIN="swift"
    CLT_ROOT="/Library/Developer/CommandLineTools"
fi

TEST_FLAGS=(
    -Xswiftc "-F$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/usr/lib"
)
