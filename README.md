# りんごのみTV（RingonomiTV）

りんごのみTVは、自分で運用する録画・視聴サーバーに接続するApple TV向けの
オープンソースtvOSアプリです。現時点の対応バックエンドはKonomiTVです。
サーバーURLは初期状態では空で、アプリの設定画面から利用者が入力します。

本アプリは、[Komorebi](https://github.com/BeerEgg2001/Komorebi)の機能と通信仕様を
参考に、Swift／SwiftUI／tvOS向けに再実装しています。参照元Androidプロジェクトの
MIT著作権表示は、このリポジトリの[`LICENSE`](LICENSE)に保持しています。

## 現在の実装

- KonomiTVのチャンネル一覧、番組情報、録画一覧
- 番組表の放送波・日付切り替え、日本語検索、番組詳細からの視聴
- 録画予約の一覧・追加・変更・削除、優先度・録画マージンなどの設定
- キーワード自動予約の作成・編集・削除、サーバー上の検索プレビュー
- キーワード条件の対象チャンネル、番組長、重複チェック、正規表現・あいまい検索
- 録画一覧での録画中・一部録画の表示
- ライブ視聴と録画再生
- 1080p、720p、540p、360pの画質選択
- 再生中の画質変更と録画のシーク
- 接続エラー、再生エラー、タイムアウト、再試行の表示
- tvOSリモコンによる再生・一時停止・録画シーク

番組表は、横にチャンネル、縦に時間を並べる形式を既定にしています。朝4時を一日の
境界とし、見出し・時間軸・現在時刻線を表示します。左右でチャンネル、上下で番組を
選び、決定で詳細を開きます。上端または戻る操作で見出しへ戻れます。
表示メニューからチャンネル別の一覧形式にも切り替えられます。番組詳細から録画予約を追加し、
「予約」タブから設定変更・削除ができます。「キーワード」から自動予約条件を管理し、
保存前に検索結果を確認できます。ジャンル・曜日時間帯などの既存条件も保持しますが、
これらの条件の編集UIは今後対応します。
副チャンネルは設定画面から表示でき、既定では主チャンネルを並べます。

予約の変更時は最新の設定を取得し、編集した項目だけを反映します。保存先などの未編集項目は
保持し、同じ項目が別の画面で変更された場合は競合を表示します。通信が途切れて操作結果が
不明な場合、追加操作を自動再送せず、一覧から結果を確認します。録画中の予約を削除すると
録画が中止されるため、画面で明示確認します。保存先や録画後処理の編集UIは未実装です。

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
PRODUCT_BUNDLE_IDENTIFIER=your.private.bundle.id \
  ./deploy.sh DEVICE_IDENTIFIER DEVELOPMENT_TEAM=TEAM_IDENTIFIER
```

DEBUGビルドでは、サーバーURLを保存せず実行時引数で指定できます。

```text
--server-url https://example.invalid:7000 --play-channel gr011
```

`--server-url`、`--play-channel`、`--play-recording`、`--show-guide`、`--show-reservations`、障害表示確認用の引数はDEBUG
ビルドだけに含まれます。

## CI

GitHub ActionsではmacOS 15上のXcode 16.4を使い、TVVLCKitバイナリを必要としない
Swiftパッケージテストと通信契約チェックを実行します。TVVLCKitを含むアプリ本体の
署名・実機検証は、各開発者のローカル環境で行います。
非公開リポジトリでは自動CIを抑止し、明示的な手動実行時だけ実行します。

## ロードマップ

1. 起動、バッファリング、画質変更、割り込みからの復帰を安定させる
2. 番組表・録画予約を仕上げ、キーワード条件の編集範囲を広げる
3. 再生位置の保存、チャプター、字幕、音声切り替え、CMスキップを追加する
4. 対応バックエンドとSMBメディアを拡張する
5. フォーカス移動、アクセシビリティ、長時間再生、リリースQAを仕上げる

各項目は、ユニットテスト、クリーンビルド、対象となるバックエンド・実機確認が
そろった時点で受け入れます。

## ライセンス

りんごのみTVのSwift／tvOSコードは[`LICENSE`](LICENSE)のMIT Licenseで提供します。
TVVLCKitはVideoLANの別コンポーネントで、GNU Lesser General Public License 2.1
です。通知文は[`App/Licenses/TVVLCKit-COPYING.txt`](App/Licenses/TVVLCKit-COPYING.txt)
に同梱しています。

参照したバックエンドAPI・依存ライブラリの出典とライセンスは
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)を参照してください。
本プロジェクトはKomorebi、KonomiTV、Appleの公式製品ではありません。
