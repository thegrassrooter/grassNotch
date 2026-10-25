#!/bin/sh
set -eu

# Keep the compiler and SDK paired by asking Xcode/Command Line Tools for its
# own default Swift toolchain instead of inheriting a separately selected one.
unset TOOLCHAINS SWIFT_EXEC SDKROOT

command_name=${1:-}
if [ -z "$command_name" ]; then
    echo "Usage: $0 {build|run|test|<swift-subcommand>} [arguments...]" >&2
    exit 2
fi
shift

case "$command_name" in
    build|run|test)
        exec /usr/bin/xcrun --toolchain com.apple.dt.toolchain.XcodeDefault \
            swift "$command_name" --build-system swiftbuild "$@"
        ;;
    *)
        exec /usr/bin/xcrun --toolchain com.apple.dt.toolchain.XcodeDefault \
            swift "$command_name" "$@"
        ;;
esac
