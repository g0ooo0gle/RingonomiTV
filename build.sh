#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ -n "${DEVELOPER_DIR:-}" ]; then
    developer_dir="$DEVELOPER_DIR"
else
    developer_dir="$(xcode-select -p 2>/dev/null || printf '%s' '/Applications/Xcode.app/Contents/Developer')"
fi
cache_root="${RINGONOMITV_CACHE_ROOT:-$PWD/.cache}"
tmp_root="${RINGONOMITV_BUILD_TMPDIR:-$PWD/.tmp}"
build_root="${RINGONOMITV_BUILD_ROOT:-$PWD/DerivedData}"
export DEVELOPER_DIR="$developer_dir"
export TMPDIR="$tmp_root"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift"
mkdir -p "$tmp_root" "$cache_root/clang" "$cache_root/swift" "$cache_root/SourcePackages" Logs

[ -d "$DEVELOPER_DIR" ] || { echo "Xcode developer directory not found: $DEVELOPER_DIR" >&2; exit 1; }
xcodegen_command="${XCODEGEN:-xcodegen}"
if [ "$xcodegen_command" = "xcodegen" ] && [ -x Tools/xcodegen/bin/xcodegen ]; then
    xcodegen_command="Tools/xcodegen/bin/xcodegen"
fi
"$xcodegen_command" generate --use-cache --cache-path "$cache_root/xcodegen-cache"

# Public builds default to unsigned output. Set CODE_SIGNING_ALLOWED=YES and
# configure a development team in Xcode for a device build.
code_signing_allowed="${CODE_SIGNING_ALLOWED:-NO}"
exec /usr/bin/xcodebuild -project RingonomiTV.xcodeproj -target RingonomiTV \
  -configuration Debug -sdk appletvos \
  -clonedSourcePackagesDirPath "$cache_root/SourcePackages" \
  SYMROOT="$build_root/Build/Products" \
  OBJROOT="$build_root/Build/Intermediates.noindex" \
  CLANG_MODULE_CACHE_PATH="$cache_root/clang" \
  CODE_SIGNING_ALLOWED="$code_signing_allowed" \
  "$@" build
