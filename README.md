# りんごのみTV（RingonomiTV）

りんごのみTVは、自分で運用する録画・視聴サーバーに接続するApple TV向けの
オープンソースtvOSアプリです。現時点の対応バックエンドはKonomiTVです。
サーバーURLは初期状態では空で、アプリの設定画面から利用者が入力します。
有料プラン、購入処理、購読処理、埋め込み済みの認証情報はありません。

本アプリは、[Komorebi](https://github.com/BeerEgg2001/Komorebi)の機能と通信仕様を
参考に、Swift／SwiftUI／tvOS向けに再実装しています。参照元Androidプロジェクトの
MIT著作権表示は、このリポジトリの[`LICENSE`](LICENSE)に保持しています。

## 現在の実装

- KonomiTVのチャンネル一覧、番組情報、録画一覧
- 番組表の放送波・日付切り替え、日本語検索、番組詳細からの視聴
- ライブ視聴と録画再生
- 1080p、720p、540p、360pの画質選択
- 再生中の画質変更と録画のシーク
- 接続エラー、再生エラー、タイムアウト、再試行の表示
- tvOSリモコンによる再生・一時停止・録画シーク

番組表は現在チャンネル別の一覧形式です。時間軸に沿って番組を並べる表示と、
録画予約の操作を順次追加します。

再生開始時に音声だけ先行して黒画面が見える状態を避けるため、ライブと録画で
別の準備処理を使います。

- **ライブ再生**はTVVLCKitを使用します。映像フレームが進み、音声も利用可能な状態が
  1秒間継続するまで画面を黒いロード表示で覆い、音声をミュートします。途中で停止した
  場合は準備状態をリセットして再開します。
- **録画再生**はAVPlayerの`seek`と`preroll`を使用します。`AVPlayerItem`と映像レイヤーが
  表示可能になるまで再生を開始せず、準備完了後にだけ画面を表示して音声を戻します。
  画質変更や再バッファリングでも同じ準備経路を通ります。

## 準備

Xcode 16.4以降、tvOS 17以降のSDK、Swift 6、macOSを使用します。XcodeGenと
TVVLCKitはGitにバイナリを含めていません。大きな依存ファイルを別ボリュームに置く
場合は、準備先を環境変数で指定できます。

```sh
RINGONOMITV_DEPENDENCY_ROOT="$PWD/.cache/dependencies" ./bootstrap.sh
```

`bootstrap.sh`は次の一次配布元から取得し、SHA-256を検証します。

| 依存物 | 取得元 | SHA-256 |
| --- | --- | --- |
| XcodeGen 2.46.0 | [公式リリース](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0) / [xcodegen.zip](https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip) | `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` |
| TVVLCKit 3.7.0 | [VideoLAN公式アーカイブ一覧](https://downloads.videolan.org/cocoapods/prod/) / [TVVLCKit-3.7.0 archive](https://downloads.videolan.org/cocoapods/prod/TVVLCKit-3.7.0-591b8996-f9020c4d.tar.xz) | `de9afabd53b914e234adf39f1f9b7f71d6f8c19bbfc009c8388a2eb0657a16e3` |

TVVLCKitの公式URLが利用できない場合、スクリプトはXcodeGenの準備までを行い、
TVVLCKitは手動配置するよう案内して終了します。推測したミラーや別のURLからは
取得しません。手動配置先は`Vendor/TVVLCKit-binary/TVVLCKit.xcframework`です。
TVVLCKitのソースとライセンスは[VideoLAN VLCKit](https://code.videolan.org/videolan/VLCKit/)
を参照してください。

準備後のSwiftパッケージテストとtvOSビルドは次のとおりです。

```sh
./test.sh
CODE_SIGNING_ALLOWED=NO ./build.sh
```

`build.sh`は`xcode-select`で選択されたXcodeを使います。別のXcodeを使う場合は
`DEVELOPER_DIR`を指定できます。生成される`RingonomiTV.xcodeproj`、TVVLCKit、
ビルド成果物、ログ、キャッシュはGit管理外です。

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
PRODUCT_BUNDLE_IDENTIFIER=your.private.bundle.id \
  ./deploy.sh DEVICE_IDENTIFIER DEVELOPMENT_TEAM=TEAM_IDENTIFIER
```

デバイス識別子、署名Team、個人用Bundle ID、サーバーURLはリポジトリに保存しません。

DEBUGビルドでは、サーバーURLを保存せず実行時引数で指定できます。

```text
--server-url https://example.invalid:7000 --play-channel gr011
```

`--server-url`、`--play-channel`、`--play-recording`、障害表示確認用の引数はDEBUG
ビルドだけに含まれます。

## CI

GitHub ActionsではmacOS 15上のXcode 16.4を使い、TVVLCKitバイナリを必要としない
Swiftパッケージテストと通信契約チェックを実行します。TVVLCKitを含むアプリ本体の
署名・実機検証は、各開発者のローカル環境で行います。

## ロードマップ

1. 起動、バッファリング、画質変更、割り込みからの復帰を安定させる
2. 番組表、検索、番組詳細、録画予約を追加する
3. 再生位置の保存、チャプター、字幕、音声切り替え、CMスキップを追加する
4. 対応バックエンドとSMBメディアを拡張する
5. フォーカス移動、アクセシビリティ、長時間再生、リリースQAを仕上げる

各項目は、ユニットテスト、クリーンビルド、対象となるバックエンド・実機確認が
そろった時点で受け入れます。個別の家庭内ネットワーク、実機情報、検証ログは
このリポジトリに保存しません。

## ライセンス

りんごのみTVのSwift／tvOSコードは[`LICENSE`](LICENSE)のMIT Licenseで提供します。
TVVLCKitはVideoLANの別コンポーネントで、GNU Lesser General Public License 2.1
以降です。通知文は[`App/Licenses/TVVLCKit-COPYING.txt`](App/Licenses/TVVLCKit-COPYING.txt)
に同梱しています。
