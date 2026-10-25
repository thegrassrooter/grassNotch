#!/bin/sh
set -eu

# Keep the compiler and SDK paired by asking Xcode/Command Line Tools for its
# own default Swift toolchain instead of inheriting a separately selected one.
unset TOOLCHAINS SWIFT_EXEC SDKROOT
exec /usr/bin/xcrun --toolchain com.apple.dt.toolchain.XcodeDefault swift "$@"
