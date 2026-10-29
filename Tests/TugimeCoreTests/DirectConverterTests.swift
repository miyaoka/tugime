import Foundation
import Testing
@testable import TugimeCore

@Suite struct ReadingAlignmentTests {
    /// 文節の読みと表記は、出力の側で位置が確定した境目で組になる
    @Test func cutsWhereKanaFixesThePosition() throws {
        let alignment = try #require(ReadingAlignment(text: "今日は", reading: "きょうは"))
        #expect(alignment.clauses(cutAt: [3]) == [JapaneseClause(reading: "きょう", text: "今日"), JapaneseClause(reading: "は", text: "は")])
        let tokyo = try #require(ReadingAlignment(text: "東京と", reading: "とうきょうと"))
        #expect(tokyo.clauses(cutAt: [5]) == [JapaneseClause(reading: "とうきょう", text: "東京"), JapaneseClause(reading: "と", text: "と")])
    }

    /// は が読みの 4 文字目と 5 文字目のどちらにも当たりうるので、私は / 歯医者 の境目は確定しない
    @Test func dropsCutsThatTheOutputCannotFix() throws {
        let alignment = try #require(ReadingAlignment(text: "私は歯医者", reading: "わたしははいしゃ"))
        #expect(alignment.clauses(cutAt: [4]) == [JapaneseClause(reading: "わたしははいしゃ", text: "私は歯医者")])
    }

    /// 錨のかな（カタカナを含む）が読みと合わない出力と、読みを食う文字が足りない出力は対応づかない
    @Test(arguments: [("コーヒー", "こおひい"), ("テストを", "あいうを"), ("今日は", "は"), ("きょう", "きょうは"), ("", "きょう")])
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
    var clauses: [String: [ScoredClause]] = [:]
    private(set) var ended = 0

    func convert(kana: String, context: JapaneseContext, ending: JapaneseEnding) -> JapaneseReading? {
        clauses[kana].map { JapaneseReading(text: $0.map(\.clause.text).joined(), value: 0, clauses: $0, context: context) }
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { [] }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? { nil }

    func naturalness(texts: [String], left: String) -> [Double]? { nil }

    func endComposition() { ended += 1 }

    func replaceUserWords(_ words: [UserWord]) {}
}

/// 決めた出力を返し、呼ばれた左の文脈と読みを記録する
private final class FixedGenerator: DirectDisplayGenerating {
    var outputs: [String: String] = [:]
    private(set) var calls: [(left: String, kana: String)] = []
    private(set) var resets = 0

    func generate(_ requests: [GenerationRequest]) -> [String] {
        requests.map { request in
            calls.append((request.left, request.kana))
            return outputs[request.kana]!
        }
    }

    func naturalness(left: String, texts: [String]) -> [Double] { texts.map { _ in 0 } }

    func reset() { resets += 1 }
}

@Suite struct DirectConverterTests {
    fileprivate let scorer = FixedScorer()
    fileprivate let generator = FixedGenerator()
    let converter: DirectConverter

    init() {
        scorer.clauses["きょうはいいてんき"] = [
            ScoredClause(JapaneseClause(reading: "きょうは", text: "今日は")), ScoredClause(JapaneseClause(reading: "いい", text: "いい")),
            ScoredClause(JapaneseClause(reading: "てんき", text: "天気")),
        ]
        converter = DirectConverter(scorer: scorer, generator: generator)
    }

    /// 読みに対応づかない出力も差し替えず、全体を 1 文節にする。読みと合わない表示として扱う
    @Test func keepsAnOutputThatDoesNotFollowTheReading() throws {
        generator.outputs["きょうはいいてんき"] = "今日はええ天気"
        let shown = try #require(converter.display(kana: "きょうはいいてんき", context: .start, left: ""))
        #expect(shown.text == "今日はええ天気")
        #expect(shown.clauses == [JapaneseClause(reading: "きょうはいいてんき", text: "今日はええ天気")])
        #expect(!shown.matchesReading)
    }

    /// 採点が利用者の語を使った文節で、出力がその語を含まなければ、その文節だけを採点の表記にする。ほかの文節は出力のまま
    @Test func replacesClausesThatMissAUserWord() throws {
        scorer.clauses["まーじゃんのまんず"] = [
            ScoredClause(JapaneseClause(reading: "まーじゃんの", text: "麻雀の")),
            ScoredClause(JapaneseClause(reading: "まんず", text: "萬子"), userWords: [UsedUserWord(reading: "マンズ", spellings: ["萬子"])]),
        ]
        generator.outputs["まーじゃんのまんず"] = "マージャンのマンズ"
        let shown = try #require(converter.display(kana: "まーじゃんのまんず", context: .start, left: ""))
        #expect(shown.text == "マージャンの萬子")
        #expect(shown.clauses == [JapaneseClause(reading: "まーじゃんの", text: "マージャンの"), JapaneseClause(reading: "まんず", text: "萬子")])
    }

    /// 利用者の語の表記にある、読みに無いかなは、読みと合わない表示として扱わない。表記をその語の読みとして照らすので、
    /// ほかの部分の書き換えと、表記が読みの数より多く現れる表示は、読みと合わない表示として扱う
    @Test func readsAUserWordAsItsReading() throws {
        scorer.clauses["よろしく"] = [ScoredClause(JapaneseClause(reading: "よろしく", text: "よろしくお願いします"), userWords: [UsedUserWord(reading: "ヨロシク", spellings: ["よろしくお願いします"])])]
        generator.outputs["よろしく"] = "宜しく"
        let shown = try #require(converter.display(kana: "よろしく", context: .start, left: ""))
        #expect(shown.text == "よろしくお願いします")
        #expect(shown.matchesReading)
        for text in ["どうぞよろしくお願いします", "よろしくお願いしますよろしくお願いします"] {
            let rewritten = JapaneseDisplay(text: text, clauses: [JapaneseClause(reading: "よろしく", text: text)], userWords: shown.userWords)
            #expect(!rewritten.matchesReading, "\(text)")
        }
    }

    /// 表記を読みに置き換えた結果を、ほかの語の表記として置き換え直さない
    @Test func replacesEachSpellingOnce() {
        let words = [UsedUserWord(reading: "カナ", spellings: ["甲乙"]), UsedUserWord(reading: "イ", spellings: ["ナ"])]
        let shown = JapaneseDisplay(text: "甲乙ナ", clauses: [JapaneseClause(reading: "かない", text: "甲乙ナ")], userWords: words)
        #expect(shown.matchesReading)
    }

    /// 利用者の語の表記が、別の読みの語の一部として表示にあっても、読みどおりの表示は読みと合う
    @Test func keepsAReadingThatMatchesWithoutTheUserWord() {
        let shown = JapaneseDisplay(text: "火が点く点", clauses: [JapaneseClause(reading: "ひがつくてん", text: "火が点く点")], userWords: [UsedUserWord(reading: "テン", spellings: ["点"])])
        #expect(shown.matchesReading)
    }

    /// 出力が利用者の語を含んでいれば、送り仮名などが採点と違っても出力のまま
    @Test func keepsAnOutputThatHasTheUserWord() throws {
        scorer.clauses["いーそうをきる"] = [ScoredClause(JapaneseClause(reading: "いーそうをきる", text: "一索を切る"), userWords: [UsedUserWord(reading: "イーソウ", spellings: ["一索"])])]
        generator.outputs["いーそうをきる"] = "一索をきる"
        let shown = try #require(converter.display(kana: "いーそうをきる", context: .start, left: ""))
        #expect(shown.text == "一索をきる")
    }

    /// 同じ読みに表記を複数登録していれば、出力がそのどれかを含むとき出力のまま
    @Test func keepsAnOutputWithAnotherRegisteredSpelling() throws {
        scorer.clauses["まんず"] = [ScoredClause(JapaneseClause(reading: "まんず", text: "萬子"), userWords: [UsedUserWord(reading: "マンズ", spellings: ["萬子", "マンズ"])])]
        generator.outputs["まんず"] = "マンズ"
        let shown = try #require(converter.display(kana: "まんず", context: .start, left: ""))
        #expect(shown.text == "マンズ")
    }

    /// 出力が読みに対応づかなければ、全体が 1 文節になり、利用者の語を含まなければ全体を採点の表記にする
    @Test func replacesTheWholeOutputWhenItDoesNotFollowTheReading() throws {
        scorer.clauses["いーそう"] = [ScoredClause(JapaneseClause(reading: "いーそう", text: "一索"), userWords: [UsedUserWord(reading: "イーソウ", spellings: ["一索"])])]
        generator.outputs["いーそう"] = "いーそお"
        let shown = try #require(converter.display(kana: "いーそう", context: .start, left: ""))
        #expect(shown.clauses == [JapaneseClause(reading: "いーそう", text: "一索")])
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
        scorer.clauses["えん"] = [ScoredClause(JapaneseClause(reading: "えん", text: "円"))]
        generator.outputs["えん"] = "円"
        _ = converter.display(kana: "えん", context: .afterNumber("100"), left: "")
        _ = converter.display(kana: "えん", context: .afterNumber("100"), left: "合計100")
        #expect(generator.calls.map(\.left) == ["100", "合計100"])
    }
}

@Suite struct ZenzPromptTests {
    /// 収まらない区切りは、読みを削らずに収まるまで半分に分ける。収まる区切りは分けない
    @Test func halvesOnlyTheChunksThatDoNotFit() {
        let parts = ZenzPrompt.halving(["あいうえおかきくけ", "さし"]) { $0.count <= 3 }
        #expect(parts == ["あい", "うえ", "おか", "きくけ", "さし"])
        #expect(parts.joined() == "あいうえおかきくけさし")
    }

    @Test func buildsTheZenzFormat() {
        #expect(ZenzPrompt.text(left: "", kana: "きょうは") == "\u{EE00}キョウハ\u{EE01}")
        #expect(ZenzPrompt.text(left: "a b\nc", kana: "ゔぁ") == "\u{EE02}a\u{3000}bc\u{EE00}ヴァ\u{EE01}")
    }

    @Test func keepsTheLast500CharactersOfContext() {
        let left = String(repeating: "あ", count: 10) + String(repeating: "い", count: 500)
        #expect(ZenzPrompt.text(left: left, kana: "う") == "\u{EE02}" + String(repeating: "い", count: 500) + "\u{EE00}ウ\u{EE01}")
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
