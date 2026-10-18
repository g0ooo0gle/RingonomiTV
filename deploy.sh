#!/bin/sh
set -eu
cd "$(dirname "$0")"

device_id="${1:?Pass the Apple TV device identifier as the first argument.}"
shift
if [ -n "${DEVELOPER_DIR:-}" ]; then
    developer_dir="$DEVELOPER_DIR"
else
    developer_dir="$(xcode-select -p 2>/dev/null || printf '%s' '/Applications/Xcode.app/Contents/Developer')"
fi
cache_root="${RINGONOMITV_CACHE_ROOT:-$PWD/.cache}"
tmp_root="${RINGONOMITV_BUILD_TMPDIR:-$PWD/.tmp}"
derived_root="${RINGONOMITV_DERIVED_DATA:-$PWD/DerivedData}"
bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-app.ringonomitv.tv}"
export DEVELOPER_DIR="$developer_dir"
export TMPDIR="$tmp_root"
mkdir -p "$cache_root/SourcePackages" "$tmp_root" Logs

[ -d "$DEVELOPER_DIR" ] || { echo "Xcode developer directory not found: $DEVELOPER_DIR" >&2; exit 1; }
xcodegen_command="${XCODEGEN:-xcodegen}"
if [ "$xcodegen_command" = "xcodegen" ] && [ -x Tools/xcodegen/bin/xcodegen ]; then
    xcodegen_command="Tools/xcodegen/bin/xcodegen"
fi
"$xcodegen_command" generate --use-cache --cache-path "$cache_root/xcodegen-cache"

"$DEVELOPER_DIR/usr/bin/xcodebuild" -project RingonomiTV.xcodeproj -scheme RingonomiTV \
  -configuration Debug -sdk appletvos -destination "id=$device_id" \
  -derivedDataPath "$derived_root" \
  -clonedSourcePackagesDirPath "$cache_root/SourcePackages" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  "$@" build

app="$derived_root/Build/Products/Debug-appletvos/RingonomiTV.app"
/usr/bin/codesign --verify --deep --strict "$app"
"$DEVELOPER_DIR/usr/bin/devicectl" device install app --device "$device_id" "$app" \
  --timeout 180 --json-output "$PWD/Logs/latest-install.json"
"$DEVELOPER_DIR/usr/bin/devicectl" device process launch --device "$device_id" \
  --terminate-existing "$bundle_id"
