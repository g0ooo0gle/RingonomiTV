# ビルドとApple TVへの配置

[READMEへ戻る](../README.md)

## 必要な環境

| 項目 | 要件 |
| --- | --- |
| 開発環境 | macOS、Xcode 16.4以降、Swift 6、tvOS 17以降のSDK |
| 字幕ライブラリのビルド | CMake 3.28以降 |
| 実機 | tvOS 17以降のApple TV HD／4K |
| 実機への配置 | Xcodeでの署名設定とApple TVのペアリング |

以下のコマンドはリポジトリのルートで実行します。

## 依存物の準備

XcodeGen、TVVLCKit、libaribcaptionはGitにバイナリを含めていません。大きな依存ファイルを
別ボリュームに置く場合は、準備先を環境変数で指定できます。

```sh
RINGONOMITV_DEPENDENCY_ROOT="$PWD/.cache/dependencies" ./bootstrap.sh
```

`bootstrap.sh`は次の一次配布元から取得し、SHA-256を検証します。

| 依存物 | 取得元 | SHA-256 |
| --- | --- | --- |
| XcodeGen 2.46.0 | [公式リリース](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0) / [xcodegen.zip](https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip) | `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` |
| TVVLCKit 3.7.0 | [VideoLAN公式アーカイブ一覧](https://downloads.videolan.org/cocoapods/prod/) / [TVVLCKit-3.7.0 archive](https://downloads.videolan.org/cocoapods/prod/TVVLCKit-3.7.0-591b8996-f9020c4d.tar.xz) | `de9afabd53b914e234adf39f1f9b7f71d6f8c19bbfc009c8388a2eb0657a16e3` |
| libaribcaption 1.1.2 | [固定コミット](https://github.com/xqq/libaribcaption/tree/37dde0f32652c32aa98bf92278944d1cfb2e7354) / [公式アーカイブ](https://codeload.github.com/xqq/libaribcaption/tar.gz/37dde0f32652c32aa98bf92278944d1cfb2e7354) | `ace54ae69e1b38481917d36161a8960ed93f51f7fd343575fab36dfe3ea072f6` |

TVVLCKitの公式URLが利用できない場合は手動配置を案内し、字幕ライブラリの準備を続けます。
アプリのビルド前にTVVLCKitを手動配置してください。推測したミラーや別のURLからは取得しません。
手動配置先は`Vendor/TVVLCKit-binary/TVVLCKit.xcframework`です。
TVVLCKitのソースとライセンスは[VideoLAN VLCKit](https://code.videolan.org/videolan/VLCKit/)
を参照してください。

字幕の描画にはlibaribcaption 1.1.2を固定コミットで使用します。`bootstrap.sh`の最後に
`prepare-captions.sh`が呼ばれ、CMake 3.28以降とXcodeのtvOS SDKで、CoreTextを有効にした
C++17の静的ライブラリをtvOS device arm64、Simulator arm64／x86_64向けに生成します。
FreeTypeとFontconfigは使用しません。2つのSimulatorアーキテクチャを`lipo`でまとめ、
`xcodebuild -create-xcframework`で`Vendor/ARIBCaption/libaribcaption.xcframework`を
作成します。生成物、ソース、アーカイブは`RINGONOMITV_DEPENDENCY_ROOT`（既定は
`.cache/dependencies`）とGit管理外の`Vendor`に置かれます。固定コミットと構成は
`Vendor/ARIBCaption/libaribcaption.version`で確認できます。

libaribcaptionの著作権表示とMITライセンスは
[`App/Licenses/libaribcaption-MIT.txt`](../App/Licenses/libaribcaption-MIT.txt)に、内蔵MD5
実装の通知は[`App/Licenses/libaribcaption-MD5-notice.txt`](../App/Licenses/libaribcaption-MD5-notice.txt)
に同梱しています。

## テストとビルド

依存物の準備後、SwiftパッケージテストとtvOSビルドを実行します。

```sh
./test.sh
CODE_SIGNING_ALLOWED=NO ./build.sh
```

`build.sh`は`xcode-select`で選択されたXcodeを使います。別のXcodeを使う場合は
`DEVELOPER_DIR`を指定できます。生成される`RingonomiTV.xcodeproj`、TVVLCKit、
ビルド成果物、ログ、キャッシュはGit管理外です。
ソースの追加・更新もXcodeGenのキャッシュで確認し、必要なときにプロジェクトを再生成します。

## Apple TVへの配置

`deploy.sh`の最初の引数はXcodeで確認したApple TVのデバイス識別子です。2番目以降の
引数はそのまま`xcodebuild`へ渡されるため、署名Teamなどのローカル設定をコマンドライン
で指定できます。

```sh
./deploy.sh DEVICE_IDENTIFIER DEVELOPMENT_TEAM=TEAM_IDENTIFIER
```

公開用の既定Bundle IDは`app.ringonomitv.tv`です。既存の個人用インストールを更新する
場合は、Bundle IDを環境変数で指定できます。

```sh
PRODUCT_BUNDLE_IDENTIFIER=app.example.ringonomitv \
  ./deploy.sh DEVICE_IDENTIFIER DEVELOPMENT_TEAM=TEAM_IDENTIFIER
```

DEBUGビルドでは、サーバーURLを保存せず実行時引数で指定できます。

```text
--server-url https://example.invalid:7000 --play-channel gr011
```

`--server-url`、`--play-channel`、`--play-recording`、`--show-recordings`、`--show-guide`、`--show-reservations`、障害表示確認用の引数はDEBUG
ビルドだけに含まれます。

## ビルド環境の変更

各スクリプトは、指定がなければ`xcode-select`で選択されたXcodeを使用します。
別のXcodeを使う場合は`DEVELOPER_DIR`を指定してください。

| 環境変数 | 用途 | 既定値 |
| --- | --- | --- |
| `RINGONOMITV_DEPENDENCY_ROOT` | 依存物のダウンロード・展開・字幕ビルド | `.cache/dependencies` |
| `RINGONOMITV_CACHE_ROOT` | ビルド用キャッシュ | `.cache` |
| `RINGONOMITV_BUILD_TMPDIR` | 一時ファイル | `.tmp` |
| `RINGONOMITV_BUILD_ROOT` | `build.sh`のビルド成果物 | `DerivedData` |
| `RINGONOMITV_DERIVED_DATA` | `deploy.sh`のDerived Data | `DerivedData` |

出典とライセンスは[第三者コンポーネントの通知](../THIRD_PARTY_NOTICES.md)を参照してください。
