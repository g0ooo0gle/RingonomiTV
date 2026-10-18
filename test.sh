#!/bin/sh
set -eu
cd "$(dirname "$0")"
cache_root="${RINGONOMITV_CACHE_ROOT:-$PWD/.cache}"
tmp_root="${RINGONOMITV_BUILD_TMPDIR:-$PWD/.tmp}"
mkdir -p "$cache_root/clang" "$cache_root/swift" "$tmp_root"
export TMPDIR="$tmp_root"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift"
if [ -n "${DEVELOPER_DIR:-}" ]; then
    developer_dir="$DEVELOPER_DIR"
else
    developer_dir="$(xcode-select -p 2>/dev/null || printf '%s' '/Applications/Xcode.app/Contents/Developer')"
fi
export DEVELOPER_DIR="$developer_dir"
swift_bin="$(xcrun --find swift)"
"$swift_bin" test --scratch-path .build --cache-path "$cache_root/swiftpm" "$@"
