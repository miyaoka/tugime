import Foundation
import Testing
@testable import TugimeCore

@Suite struct ReadingAlignmentTests {
    @Test func cutsWhereKanaFixesThePosition() throws {
        let alignment = try #require(ReadingAlignment(text: "今日は", reading: "きょうは"))
        #expect(alignment.clauses(cutAt: [3]) == [JapaneseClause(reading: "きょう", text: "今日"), JapaneseClause(reading: "は", text: "は")])
        let tokyo = try #require(ReadingAlignment(text: "東京と", reading: "とうきょうと"))
        #expect(tokyo.clauses(cutAt: [5]) == [JapaneseClause(reading: "とうきょう", text: "東京"), JapaneseClause(reading: "と", text: "と")])
    }

    @Test func katakanaIsAnAnchor() throws {
        let alignment = try #require(ReadingAlignment(text: "テストを", reading: "てすとを"))
        #expect(alignment.clauses(cutAt: [3]) == [JapaneseClause(reading: "てすと", text: "テスト"), JapaneseClause(reading: "を", text: "を")])
    }

    /// は が読みの 4 文字目と 5 文字目のどちらにも当たりうるので、私は / 歯医者 の境目は確定しない
    @Test func dropsCutsThatTheOutputCannotFix() throws {
        let alignment = try #require(ReadingAlignment(text: "私は歯医者", reading: "わたしははいしゃ"))
        #expect(alignment.clauses(cutAt: [4]) == [JapaneseClause(reading: "わたしははいしゃ", text: "私は歯医者")])
    }

    /// 錨のかなが読みと合わない出力と、読みを食う文字が足りない出力は対応づかない
    @Test(arguments: [("コーヒー", "こおひい"), ("今日は", "は"), ("きょう", "きょうは"), ("", "きょう")])
    func rejectsOutputsThatDoNotFollowTheReading(text: String, reading: String) {
        #expect(ReadingAlignment(text: text, reading: reading) == nil)
    }

    /// どの切り方でも、読みを繋ぐと読み、表記を繋ぐと出力になる
    @Test(arguments: [("今日はいい天気", "きょうはいいてんき"), ("東京特許許可局", "とうきょうとっきょきょかきょく"), ("骨董品３００点が盗難", "こっとうひんさんびゃくてんがとうなん")])
    func clausesJoinBackToReadingAndText(text: String, reading: String) throws {
        let alignment = try #require(ReadingAlignment(text: text, reading: reading))
        for cut in 1..<reading.count {
            let clauses = alignment.clauses(cutAt: [cut])
            #expect(clauses.map(\.reading).joined() == reading)
            #expect(clauses.map(\.text).joined() == text)
            #expect(clauses.allSatisfy { !$0.reading.isEmpty && !$0.text.isEmpty })
        }
    }
}

/// 採点は決めた文節で返し、候補は空にする
private final class FixedScorer: JapaneseConverting {
    var clauses: [String: [JapaneseClause]] = [:]
    private(set) var ended = 0

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        clauses[kana].map { JapaneseReading(text: $0.map(\.text).joined(), value: 0, clauses: $0, context: context) }
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { [] }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? { nil }

    func endComposition() { ended += 1 }
}

/// 決めた出力を返し、呼ばれた左の文脈と読みを記録する
private final class FixedGenerator: DirectDisplayGenerating {
    var outputs: [String: String] = [:]
    private(set) var calls: [(left: String, kana: String)] = []
    private(set) var resets = 0

    func generate(left: String, kana: String) -> String {
        calls.append((left, kana))
        return outputs[kana]!
    }

    func reset() { resets += 1 }
}

@Suite struct DirectConverterTests {
    fileprivate let scorer = FixedScorer()
    fileprivate let generator = FixedGenerator()
    let converter: DirectConverter

    init() {
        scorer.clauses["きょうはいいてんき"] = [
            JapaneseClause(reading: "きょうは", text: "今日は"), JapaneseClause(reading: "いい", text: "いい"), JapaneseClause(reading: "てんき", text: "天気"),
        ]
        converter = DirectConverter(scorer: scorer, generator: generator)
    }

    /// 表示は生成の出力そのもので、文節の境目は採点の境目のうち出力の側で確定したもの
    @Test func showsTheModelOutputWithTheScorersClauses() throws {
        generator.outputs["きょうはいいてんき"] = "今日はいい天気"
        let shown = try #require(converter.display(kana: "きょうはいいてんき", context: .start, left: ""))
        #expect(shown.text == "今日はいい天気")
        #expect(shown.clauses == [
            JapaneseClause(reading: "きょうは", text: "今日は"), JapaneseClause(reading: "いい", text: "いい"), JapaneseClause(reading: "てんき", text: "天気"),
        ])
    }

    /// 読みに対応づかない出力も差し替えず、全体を 1 文節にする
    @Test func keepsAnOutputThatDoesNotFollowTheReading() throws {
        generator.outputs["きょうはいいてんき"] = "今日はええ天気"
        let shown = try #require(converter.display(kana: "きょうはいいてんき", context: .start, left: ""))
        #expect(shown.text == "今日はええ天気")
        #expect(shown.clauses == [JapaneseClause(reading: "きょうはいいてんき", text: "今日はええ天気")])
    }

    @Test func returnsNothingWhereTheScorerReturnsNothing() {
        #expect(converter.display(kana: "ん", context: .start, left: "") == nil)
        #expect(generator.calls.isEmpty)
    }

    /// 確定・取り消しで、採点と生成の両方が覚えたものを捨てる（JapaneseConverting.endComposition の約束）
    @Test func endCompositionDropsWhatTheConvertersRemembered() {
        generator.outputs["きょうはいいてんき"] = "今日はいい天気"
        _ = converter.display(kana: "きょうはいいてんき", context: .start, left: "")
        converter.endComposition()
        #expect(generator.resets == 1)
        #expect(scorer.ended == 1)
    }

    /// 入力欄に確定済みの数字に続く区間は、その数字を左の文脈にする
    @Test func passesConfirmedDigitsAsTheLeftContext() {
        scorer.clauses["えん"] = [JapaneseClause(reading: "えん", text: "円")]
        generator.outputs["えん"] = "円"
        _ = converter.display(kana: "えん", context: .afterNumber("100"), left: "")
        _ = converter.display(kana: "えん", context: .afterNumber("100"), left: "合計100")
        #expect(generator.calls.map(\.left) == ["100", "合計100"])
    }
}

@Suite struct ZenzPromptTests {
    @Test func buildsTheZenzFormat() {
        #expect(ZenzPrompt.text(left: "", kana: "きょうは") == "\u{EE00}キョウハ\u{EE01}")
        #expect(ZenzPrompt.text(left: "a b\nc", kana: "ゔぁ") == "\u{EE02}a\u{3000}bc\u{EE00}ヴァ\u{EE01}")
    }

    @Test func keepsTheLast500CharactersOfContext() {
        let left = String(repeating: "あ", count: 10) + String(repeating: "い", count: 500)
        #expect(ZenzPrompt.text(left: left, kana: "う") == "\u{EE02}" + String(repeating: "い", count: 500) + "\u{EE00}ウ\u{EE01}")
    }

    @Test func cutsTheOutputAtTheFirstNewline() {
        #expect(ZenzPrompt.cutAtNewline("今日は\n明日は") == "今日は")
        #expect(ZenzPrompt.cutAtNewline("今日は") == "今日は")
    }

    /// 40 字以下は分けない。超えたら句読点で終わる部分を 40 字以内にまとめる
    @Test func splitsLongReadingsAtPunctuation() {
        let short = String(repeating: "あ", count: 40)
        #expect(ZenzPrompt.chunks(short, maxLength: 387) == [short])
        let a = String(repeating: "あ", count: 25) + "、"
        let b = String(repeating: "い", count: 10) + "。"
        let c = String(repeating: "う", count: 20)
        #expect(ZenzPrompt.chunks(a + b + c, maxLength: 387) == [a + b, c])
    }

    /// 句読点の無い長い読みは、出力と合わせてモデルの位置に収まる長さで区切る
    @Test func splitsLongReadingsWithoutPunctuationByLength() {
        #expect(ZenzPrompt.maxChunkLength(positions: 1024) == 387)
        let long = String(repeating: "あ", count: 120)
        let parts = ZenzPrompt.chunks(long, maxLength: 50)
        #expect(parts.map(\.count) == [50, 50, 20])
        #expect(parts.joined() == long)
    }
}
