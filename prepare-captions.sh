#!/bin/sh
set -eu

# Build the pinned libaribcaption source for tvOS and assemble a static
# XCFramework. Archives, source trees, build trees, and outputs live under
# the dependency cache or the ignored Vendor directory; no generated binary
# is tracked by this repository.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dependency_root=${RINGONOMITV_DEPENDENCY_ROOT:-"$repo_root/.cache/dependencies"}
download_root="$dependency_root/downloads"
source_root="$dependency_root/sources"
build_root="$dependency_root/build"
staging_root="$dependency_root/staging"

libaribcaption_commit=37dde0f32652c32aa98bf92278944d1cfb2e7354
libaribcaption_version=1.1.2
libaribcaption_url="https://codeload.github.com/xqq/libaribcaption/tar.gz/$libaribcaption_commit"
libaribcaption_sha256=ace54ae69e1b38481917d36161a8960ed93f51f7fd343575fab36dfe3ea072f6
libaribcaption_archive=${RINGONOMITV_LIBARIBCAPTION_ARCHIVE:-"$download_root/libaribcaption-$libaribcaption_commit.tar.gz"}
source_dir="$source_root/libaribcaption-$libaribcaption_commit"

vendor_dir="$repo_root/Vendor/ARIBCaption"
xcframework_output="$vendor_dir/libaribcaption.xcframework"
version_output="$vendor_dir/libaribcaption.version"

minimum_tvos=${RINGONOMITV_TVOS_DEPLOYMENT_TARGET:-17.0}
build_jobs=${RINGONOMITV_CAPTION_BUILD_JOBS:-2}
cmake_generator=${RINGONOMITV_CMAKE_GENERATOR:-Unix\ Makefiles}
run_id="$libaribcaption_commit-$(date +%Y%m%d%H%M%S)-$$"
run_root="$staging_root/libaribcaption-$run_id"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 が必要です。"
}

sha256_for() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "shasum または sha256sum が必要です。"
    fi
}

verify_sha256() {
    expected=$1
    file=$2
    actual=$(sha256_for "$file")
    if [ "$actual" != "$expected" ]; then
        printf 'SHA-256 mismatch: %s\nexpected: %s\nactual:   %s\n' \
            "$file" "$expected" "$actual" >&2
        return 1
    fi
}

download_verified() {
    url=$1
    expected=$2
    destination=$3

    mkdir -p "$(dirname "$destination")"
    if [ -f "$destination" ]; then
        verify_sha256 "$expected" "$destination" || die "検証に失敗した既存アーカイブを差し替えてください: $destination"
        printf '検証済みアーカイブを再利用します: %s\n' "$destination"
        return 0
    fi

    require_command curl
    temporary="$destination.partial.$$"
    printf 'libaribcaption %s を取得します: %s\n' "$libaribcaption_version" "$url"
    if ! curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 \
        --output "$temporary" "$url"; then
        printf 'アーカイブ取得に失敗しました。途中ファイルを確認してください: %s\n' "$temporary" >&2
        return 1
    fi
    if ! verify_sha256 "$expected" "$temporary"; then
        printf '取得したアーカイブのSHA-256が一致しません: %s\n' "$temporary" >&2
        return 1
    fi
    mv "$temporary" "$destination"
}

prepare_source() {
    if [ -d "$source_dir" ]; then
        [ -f "$source_dir/CMakeLists.txt" ] || die "既存のlibaribcaptionソースが不完全です: $source_dir"
        printf '固定コミットのソースを再利用します: %s\n' "$source_dir"
        return 0
    fi

    require_command tar
    mkdir -p "$source_root"
    extract_root="$source_root/.extract-$run_id"
    mkdir -p "$extract_root"
    tar -xzf "$libaribcaption_archive" -C "$extract_root"
    extracted_source=$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$extracted_source" ] || die "libaribcaptionアーカイブの展開先を見つけられません。"
    [ ! -e "$source_dir" ] || die "展開先が途中で作成されました。既存ディレクトリを確認してください: $source_dir"
    mv "$extracted_source" "$source_dir"
    printf '固定コミットのソースを配置しました: %s\n' "$source_dir"
}

check_cmake() {
    cmake_bin=${RINGONOMITV_CMAKE:-"$(command -v cmake || true)"}
    [ -n "$cmake_bin" ] || die "CMake 3.28以降が必要です。"
    cmake_version=$("$cmake_bin" --version | sed -n '1s/^cmake version //p')
    cmake_major=$(printf '%s' "$cmake_version" | awk -F. '{print $1}')
    cmake_minor=$(printf '%s' "$cmake_version" | awk -F. '{print $2}')
    case "$cmake_major:$cmake_minor" in
        ''|:*|*:)
            die "CMakeのバージョンを判定できません: $cmake_version"
            ;;
    esac
    if [ "$cmake_major" -lt 3 ] || {
        [ "$cmake_major" -eq 3 ] && [ "$cmake_minor" -lt 28 ]
    }; then
        die "CMake 3.28以降が必要です。検出値: $cmake_version"
    fi
}

check_xcode_sdks() {
    xcrun_bin=${RINGONOMITV_XCRUN:-"$(command -v xcrun || true)"}
    [ -n "$xcrun_bin" ] || die "Xcodeのxcrunが必要です。"
    device_sdk_path=$("$xcrun_bin" --sdk appletvos --show-sdk-path)
    simulator_sdk_path=$("$xcrun_bin" --sdk appletvsimulator --show-sdk-path)
    device_sdk_version=$("$xcrun_bin" --sdk appletvos --show-sdk-version)
    simulator_sdk_version=$("$xcrun_bin" --sdk appletvsimulator --show-sdk-version)
    device_clang=$("$xcrun_bin" --sdk appletvos --find clang)
    device_clangxx=$("$xcrun_bin" --sdk appletvos --find clang++)
    simulator_clang=$("$xcrun_bin" --sdk appletvsimulator --find clang)
    simulator_clangxx=$("$xcrun_bin" --sdk appletvsimulator --find clang++)
    [ -d "$device_sdk_path" ] || die "tvOS device SDKを見つけられません。"
    [ -d "$simulator_sdk_path" ] || die "tvOS Simulator SDKを見つけられません。"
}

configure_and_install() {
    platform_name=$1
    sdk_name=$2
    sdk_path=$3
    arch=$4
    c_compiler=$5
    cxx_compiler=$6
    sdk_version=$7

    build_dir="$run_root/build-$platform_name"
    install_dir="$run_root/install-$platform_name"
    mkdir -p "$build_dir" "$install_dir"
    "$cmake_bin" -S "$source_dir" -B "$build_dir" \
        -G "$cmake_generator" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=tvOS \
        -DCMAKE_OSX_SYSROOT="$sdk_path" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum_tvos" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_C_COMPILER="$c_compiler" \
        -DCMAKE_CXX_COMPILER="$cxx_compiler" \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_CXX_EXTENSIONS=OFF \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DARIBCC_BUILD_TESTS=OFF \
        -DARIBCC_SHARED_LIBRARY=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DARIBCC_USE_CORETEXT=ON \
        -DARIBCC_USE_FREETYPE=OFF \
        -DARIBCC_USE_FONTCONFIG=OFF \
        -DARIBCC_USE_EMBEDDED_FREETYPE=OFF \
        -DARIBCC_NO_EXCEPTIONS=OFF \
        -DARIBCC_NO_RTTI=OFF
    "$cmake_bin" --build "$build_dir" --config Release --parallel "$build_jobs"
    "$cmake_bin" --install "$build_dir" --config Release

    static_library="$install_dir/lib/libaribcaption.a"
    [ -f "$static_library" ] || die "静的ライブラリが生成されませんでした: $static_library"
    [ -f "$install_dir/include/aribcaption/aribcaption.h" ] || \
        die "公開ヘッダーがインストールされませんでした: $install_dir/include/aribcaption/aribcaption.h"
    stamp_dir="$install_dir/share/ringonomitv"
    mkdir -p "$stamp_dir"
    cat > "$stamp_dir/libaribcaption.version" <<EOF
libaribcaption_version=$libaribcaption_version
libaribcaption_commit=$libaribcaption_commit
architecture=$arch
sdk=$sdk_name
sdk_version=$sdk_version
EOF
    configured_install_dir=$install_dir
}

assemble_simulator_library() {
    sim_arm64_install=$1
    sim_x86_64_install=$2
    sim_universal_install="$run_root/install-simulator-universal"
    mkdir -p "$sim_universal_install/lib" "$sim_universal_install/include"
    require_command lipo
    lipo -create \
        "$sim_arm64_install/lib/libaribcaption.a" \
        "$sim_x86_64_install/lib/libaribcaption.a" \
        -output "$sim_universal_install/lib/libaribcaption.a"
    cp -R "$sim_arm64_install/include/." "$sim_universal_install/include/"
    mkdir -p "$sim_universal_install/share/ringonomitv"
    cat > "$sim_universal_install/share/ringonomitv/libaribcaption.version" <<EOF
libaribcaption_version=$libaribcaption_version
libaribcaption_commit=$libaribcaption_commit
architecture=arm64+x86_64
sdk=appletvsimulator
sdk_version=$simulator_sdk_version
EOF
    assembled_simulator_install_dir=$sim_universal_install
}

replace_artifact() {
    staged_xcframework=$1
    staged_version=$2
    mkdir -p "$vendor_dir" "$staging_root/backups"

    old_xcframework=""
    old_version=""
    if [ -e "$xcframework_output" ] || [ -L "$xcframework_output" ]; then
        old_xcframework="$staging_root/backups/libaribcaption.xcframework.$run_id"
        if ! mv "$xcframework_output" "$old_xcframework"; then
            die "既存XCFrameworkを退避できないため処理を中止しました。既存成果物は変更していません。"
        fi
    fi
    if [ -e "$version_output" ] || [ -L "$version_output" ]; then
        old_version="$staging_root/backups/libaribcaption.version.$run_id"
        if ! mv "$version_output" "$old_version"; then
            [ -z "$old_xcframework" ] || mv "$old_xcframework" "$xcframework_output" || true
            die "既存バージョンスタンプを退避できないため処理を中止しました。既存成果物を復元しました。"
        fi
    fi

    if ! mv "$staged_xcframework" "$xcframework_output"; then
        [ -z "$old_xcframework" ] || mv "$old_xcframework" "$xcframework_output"
        [ -z "$old_version" ] || mv "$old_version" "$version_output"
        die "XCFrameworkの配置に失敗しました。既存成果物を復元しました。"
    fi
    if ! mv "$staged_version" "$version_output"; then
        failed_xcframework="$staging_root/backups/libaribcaption.xcframework.failed.$run_id"
        mv "$xcframework_output" "$failed_xcframework" || true
        [ -z "$old_xcframework" ] || mv "$old_xcframework" "$xcframework_output"
        [ -z "$old_version" ] || mv "$old_version" "$version_output"
        die "バージョンスタンプの配置に失敗しました。既存成果物を復元しました。"
    fi

    if [ -n "$old_xcframework" ] || [ -n "$old_version" ]; then
        printf '既存成果物の退避先: %s/backups\n' "$staging_root"
    fi
}

mkdir -p "$download_root" "$source_root" "$build_root" "$staging_root" "$run_root"
require_command awk
require_command find
require_command mv
require_command cp
require_command date

download_verified "$libaribcaption_url" "$libaribcaption_sha256" "$libaribcaption_archive" \
    || die "libaribcaptionの公式アーカイブを取得できませんでした。"
prepare_source
check_cmake
check_xcode_sdks

configure_and_install \
    device appletvos "$device_sdk_path" arm64 "$device_clang" "$device_clangxx" "$device_sdk_version"
device_install=$configured_install_dir
configure_and_install \
    simulator-arm64 appletvsimulator "$simulator_sdk_path" arm64 "$simulator_clang" "$simulator_clangxx" "$simulator_sdk_version"
sim_arm64_install=$configured_install_dir
configure_and_install \
    simulator-x86_64 appletvsimulator "$simulator_sdk_path" x86_64 "$simulator_clang" "$simulator_clangxx" "$simulator_sdk_version"
sim_x86_64_install=$configured_install_dir
assemble_simulator_library "$sim_arm64_install" "$sim_x86_64_install"
sim_universal_install=$assembled_simulator_install_dir

require_command xcodebuild
staged_artifact_root="$run_root/artifact"
staged_xcframework="$staged_artifact_root/libaribcaption.xcframework"
staged_version="$staged_artifact_root/libaribcaption.version"
mkdir -p "$staged_artifact_root"

# Static libraries need their public include tree supplied separately to
# xcodebuild so consumers can import the C API alongside the static binary.
xcodebuild -create-xcframework \
    -library "$device_install/lib/libaribcaption.a" \
    -headers "$device_install/include" \
    -library "$sim_universal_install/lib/libaribcaption.a" \
    -headers "$sim_universal_install/include" \
    -output "$staged_xcframework"

cat > "$staged_version" <<EOF
libaribcaption_version=$libaribcaption_version
libaribcaption_commit=$libaribcaption_commit
archive_sha256=$libaribcaption_sha256
device_architecture=arm64
device_sdk=appletvos
device_sdk_version=$device_sdk_version
simulator_architectures=arm64+x86_64
simulator_sdk=appletvsimulator
simulator_sdk_version=$simulator_sdk_version
cmake_version=$cmake_version
EOF

replace_artifact "$staged_xcframework" "$staged_version"
printf '%s\n' "libaribcaption $libaribcaption_version のtvOS用静的XCFrameworkを配置しました。"
printf '%s\n' "出力: $xcframework_output"
printf '%s\n' "識別情報: $version_output"
