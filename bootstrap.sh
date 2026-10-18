#!/bin/sh
set -eu

cd "$(dirname "$0")"
repo_root=$PWD

dependency_root="${RINGONOMITV_DEPENDENCY_ROOT:-$repo_root/.cache/dependencies}"
download_root="$dependency_root/downloads"
stage_root="$dependency_root/staging"

xcodegen_version=2.46.0
xcodegen_url="https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
xcodegen_archive="${RINGONOMITV_XCODEGEN_ARCHIVE:-$download_root/xcodegen.zip}"

tvvlckit_version=3.7.0
tvvlckit_url="https://downloads.videolan.org/cocoapods/prod/TVVLCKit-3.7.0-591b8996-f9020c4d.tar.xz"
tvvlckit_sha256=de9afabd53b914e234adf39f1f9b7f71d6f8c19bbfc009c8388a2eb0657a16e3
tvvlckit_archive="${RINGONOMITV_TVVLCKIT_ARCHIVE:-$download_root/TVVLCKit-3.7.0-591b8996-f9020c4d.tar.xz}"

xcodegen_bin="$repo_root/Tools/xcodegen/bin/xcodegen"
tvvlckit_framework="$repo_root/Vendor/TVVLCKit-binary/TVVLCKit.xcframework"

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

manual_tvvlckit() {
    printf '%s\n' "TVVLCKit $tvvlckit_version の自動取得を完了できませんでした。"
    printf '%s\n' "公式アーカイブ: $tvvlckit_url"
    printf '%s\n' "SHA-256: $tvvlckit_sha256"
    printf '%s\n' "取得後に $tvvlckit_framework を配置してから再実行してください。"
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
        printf 'SHA-256 mismatch: %s\nexpected: %s\nactual:   %s\n' "$file" "$expected" "$actual" >&2
        return 1
    fi
}

download_verified() {
    url=$1
    expected=$2
    destination=$3

    mkdir -p "$(dirname "$destination")"
    if [ -f "$destination" ]; then
        if verify_sha256 "$expected" "$destination"; then
            printf '検証済みアーカイブを再利用します: %s\n' "$destination"
            return 0
        fi
        printf '既存ファイルのハッシュが一致しないため停止します。削除または差し替えてください: %s\n' "$destination" >&2
        return 1
    fi

    command -v curl >/dev/null 2>&1 || {
        printf 'curl がないため取得できません: %s\n' "$url" >&2
        return 1
    }

    temporary="$destination.download.$$"
    rm -f "$temporary"
    printf '取得中: %s\n' "$url"
    if ! curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 \
        --output "$temporary" "$url"; then
        rm -f "$temporary"
        return 1
    fi
    if ! verify_sha256 "$expected" "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    mv "$temporary" "$destination"
}

prepare_xcodegen() {
    if [ -x "$xcodegen_bin" ]; then
        version=$("$xcodegen_bin" --version 2>/dev/null || true)
        case "$version" in
            *"$xcodegen_version"*)
                printf 'XcodeGen %s を再利用します。\n' "$xcodegen_version"
                return 0
                ;;
            *)
                die "Tools/xcodegen/bin/xcodegen は $xcodegen_version ではありません。既存のツールを確認してください。"
                ;;
        esac
    fi

    if [ -L "$repo_root/Tools" ]; then
        die "Tools は既存のシンボリックリンクですがXcodeGenがありません。リンク先を確認してください。"
    fi
    command -v unzip >/dev/null 2>&1 || die "unzip が必要です。"
    download_verified "$xcodegen_url" "$xcodegen_sha256" "$xcodegen_archive" \
        || die "XcodeGen $xcodegen_version を公式リリースから取得できませんでした。"

    stage="$stage_root/xcodegen-$xcodegen_version"
    mkdir -p "$stage"
    unzip -q -o "$xcodegen_archive" -d "$stage"
    extracted_bin=$(find "$stage" -type f -name xcodegen -print -quit)
    [ -n "$extracted_bin" ] || die "XcodeGenアーカイブに実行ファイルがありません。"

    mkdir -p "$(dirname "$xcodegen_bin")"
    cp "$extracted_bin" "$xcodegen_bin"
    chmod +x "$xcodegen_bin"

    extracted_presets=$(find "$stage" -type d -name SettingPresets -print -quit || true)
    if [ -n "$extracted_presets" ]; then
        presets_root="$repo_root/Tools/xcodegen/share/xcodegen/SettingPresets"
        mkdir -p "$presets_root"
        cp -R "$extracted_presets"/. "$presets_root"/
    fi

    version=$("$xcodegen_bin" --version 2>/dev/null || true)
    case "$version" in
        *"$xcodegen_version"*) ;;
        *) die "導入したXcodeGenのバージョンを確認できません: $version" ;;
    esac
    printf 'XcodeGen %s の準備が完了しました。\n' "$xcodegen_version"
}

prepare_tvvlckit() {
    if [ -d "$tvvlckit_framework" ]; then
        printf 'TVVLCKit %s を再利用します。\n' "$tvvlckit_version"
        return 0
    fi

    if [ -L "$repo_root/Vendor" ]; then
        manual_tvvlckit
        return 0
    fi

    if ! download_verified "$tvvlckit_url" "$tvvlckit_sha256" "$tvvlckit_archive"; then
        manual_tvvlckit
        return 0
    fi

    command -v tar >/dev/null 2>&1 || {
        manual_tvvlckit
        return 0
    }
    stage="$stage_root/tvvlckit-$tvvlckit_version"
    mkdir -p "$stage"
    if ! tar -xJf "$tvvlckit_archive" -C "$stage"; then
        manual_tvvlckit
        return 0
    fi
    extracted_framework=$(find "$stage" -type d -name TVVLCKit.xcframework -print -quit || true)
    if [ -z "$extracted_framework" ]; then
        manual_tvvlckit
        return 0
    fi

    mkdir -p "$repo_root/Vendor/TVVLCKit-binary"
    cp -R "$extracted_framework" "$repo_root/Vendor/TVVLCKit-binary/"
    if [ ! -d "$tvvlckit_framework" ]; then
        manual_tvvlckit
        return 0
    fi
    printf 'TVVLCKit %s の準備が完了しました。\n' "$tvvlckit_version"
}

mkdir -p "$download_root" "$stage_root"
prepare_xcodegen
prepare_tvvlckit

printf '%s\n' "依存物の準備処理が完了しました。XcodeGenとTVVLCKitの配置を確認してからbuild.shを実行してください。"
