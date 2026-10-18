import Foundation

/// One concrete middle genre accepted by the keyword-search API.
public struct KeywordGenreMiddle: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(major: String, name: String) {
        self.id = "genre-middle:\(major):\(name)"
        self.name = name
    }
}

/// One ARIB major genre and its concrete middle genres.
public struct KeywordGenreMajor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let middles: [KeywordGenreMiddle]

    public init(name: String, middles: [String]) {
        self.id = "genre-major:\(name)"
        self.name = name
        // KonomiTV's official picker represents a whole-major condition with
        // the concrete middle value "すべて".  Keep it in every major rather
        // than inventing an empty-middle payload (which the API rejects).
        var names = ["すべて"]
        names.append(contentsOf: middles.filter { $0 != "すべて" })
        self.middles = names.map { KeywordGenreMiddle(major: name, name: $0) }
    }
}

/// The deterministic ARIB genre catalog used by the keyword-condition UI.
///
/// KonomiTV converts the ARIB content descriptor table to these Japanese
/// names and replaces the full-width slash in a major label with `・`.  The
/// catalog contains the 13 standard major genres and the official whole-major
/// middle value `すべて`.  Server values outside this table remain visible as
/// unknown values in the editor and are never discarded.
public enum KeywordGenreCatalog {
    public static let all: [KeywordGenreMajor] = [
        KeywordGenreMajor(name: "ニュース・報道", middles: [
            "定時・総合", "天気", "特集・ドキュメント", "政治・国会", "経済・市況", "海外・国際",
            "解説", "討論・会談", "報道特番", "ローカル・地域", "交通", "その他"
        ]),
        KeywordGenreMajor(name: "スポーツ", middles: [
            "スポーツニュース", "野球", "サッカー", "ゴルフ", "その他の球技", "相撲・格闘技",
            "オリンピック・国際大会", "マラソン・陸上・水泳", "モータースポーツ",
            "マリン・ウィンタースポーツ", "競馬・公営競技", "その他"
        ]),
        KeywordGenreMajor(name: "情報・ワイドショー", middles: [
            "芸能・ワイドショー", "ファッション", "暮らし・住まい", "健康・医療", "ショッピング・通販",
            "グルメ・料理", "イベント", "番組紹介・お知らせ", "その他"
        ]),
        KeywordGenreMajor(name: "ドラマ", middles: [
            "国内ドラマ", "海外ドラマ", "時代劇", "その他"
        ]),
        KeywordGenreMajor(name: "音楽", middles: [
            "国内ロック・ポップス", "海外ロック・ポップス", "クラシック・オペラ", "ジャズ・フュージョン",
            "歌謡曲・演歌", "ライブ・コンサート", "ランキング・リクエスト", "カラオケ・のど自慢",
            "民謡・邦楽", "童謡・キッズ", "民族音楽・ワールドミュージック", "その他"
        ]),
        KeywordGenreMajor(name: "バラエティ", middles: [
            "クイズ", "ゲーム", "トークバラエティ", "お笑い・コメディ", "音楽バラエティ", "旅バラエティ",
            "料理バラエティ", "その他"
        ]),
        KeywordGenreMajor(name: "映画", middles: [
            "洋画", "邦画", "アニメ", "その他"
        ]),
        KeywordGenreMajor(name: "アニメ・特撮", middles: [
            "国内アニメ", "海外アニメ", "特撮", "その他"
        ]),
        KeywordGenreMajor(name: "ドキュメンタリー・教養", middles: [
            "社会・時事", "歴史・紀行", "自然・動物・環境", "宇宙・科学・医学", "カルチャー・伝統文化",
            "文学・文芸", "スポーツ", "ドキュメンタリー全般", "インタビュー・討論", "その他"
        ]),
        KeywordGenreMajor(name: "劇場・公演", middles: [
            "現代劇・新劇", "ミュージカル", "ダンス・バレエ", "落語・演芸", "歌舞伎・古典", "その他"
        ]),
        KeywordGenreMajor(name: "趣味・教育", middles: [
            "旅・釣り・アウトドア", "園芸・ペット・手芸", "音楽・美術・工芸", "囲碁・将棋", "麻雀・パチンコ",
            "車・オートバイ", "コンピュータ・ＴＶゲーム", "会話・語学", "幼児・小学生", "中学生・高校生",
            "大学生・受験", "生涯教育・資格", "教育問題", "その他"
        ]),
        KeywordGenreMajor(name: "福祉", middles: [
            "高齢者", "障害者", "社会福祉", "ボランティア", "手話", "文字（字幕）", "音声解説", "その他"
        ]),
        KeywordGenreMajor(name: "その他", middles: ["その他"])
    ]

    /// Alias for call sites that describe the values as majors.
    public static var majors: [KeywordGenreMajor] { all }

    public static func major(named name: String) -> KeywordGenreMajor? {
        all.first { $0.name == name }
    }

    public static func middle(named name: String, inMajor major: String) -> KeywordGenreMiddle? {
        Self.major(named: major)?.middles.first { $0.name == name }
    }
}
