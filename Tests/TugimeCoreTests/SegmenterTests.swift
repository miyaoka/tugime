import Testing
@testable import TugimeCore

/// かなをそのまま返す変換。評価値は長さに比例させ、区切りの規則だけを見る。文節は 2 かなずつに分ける
private final class KanaEcho: JapaneseConverting {
    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        let chars = Array(kana)
        let clauses = stride(from: 0, to: chars.count, by: 2).map {
            let part = String(chars[$0..<min($0 + 2, chars.count)])
            return JapaneseClause(reading: part, text: part)
        }
        return JapaneseReading(text: kana, value: -2 * Double(kana.count), clauses: clauses, context: context == .afterCaret ? .afterWord : context)
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { [kana] }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        convert(kana: kana, context: context).map { JapaneseDisplay(text: $0.text, clauses: $0.clauses) }
    }

    func endComposition() {}
}

/// 長い読みほど評価値が長さ以上に下がる変換。読めるローマ字を日本語区間に分ける区切りを選ばせる。
/// 変換結果は読みを [] で囲み、どの読みを 1 回で変換したかを出力から読めるようにする。maxLength より長い読みは変換できない
private final class LongReadingPenalty: JapaneseConverting {
    let maxLength: Int

    init(maxLength: Int = .max) {
        self.maxLength = maxLength
    }

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        guard kana.count <= maxLength else { return nil }
        let text = "[\(kana)]"
        return JapaneseReading(text: text, value: -Double(kana.count * kana.count), clauses: [JapaneseClause(reading: kana, text: text)], context: context == .afterCaret ? .afterWord : context)
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { [kana] }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        convert(kana: kana, context: context).map { JapaneseDisplay(text: $0.text, clauses: $0.clauses) }
    }

    func endComposition() {}
}

@Suite struct JapaneseSpanJoinTests {
    @Test func readableRomajiStaysOneJapaneseSpan() throws {
        let segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: LongReadingPenalty())
        let segments = segmenter.segment("jaasousiro")
        #expect(segments.map(\.kind) == [.japanese])
        #expect(segments.map(\.output) == ["[じゃあそうしろ]"])
    }

    @Test func spansStaySplitWhenTheJoinedReadingCannotBeConverted() throws {
        let segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: LongReadingPenalty(maxLength: 4))
        let segments = segmenter.segment("jaasousiro")
        #expect(segments.map(\.kind).allSatisfy { $0 == .japanese })
        #expect(segments.count > 1)
        #expect(segments.map(\.reading).joined() == "じゃあそうしろ")
        #expect(segments.allSatisfy { $0.output == "[\($0.reading)]" })
        #expect(segmenter.clauses("jaasousiro").map(\.output).joined() == segments.map(\.output).joined())
    }
}

@Suite struct ClauseConversionTests {
    let segmenter: Segmenter

    init() throws {
        segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: KanaEcho())
    }

    /// KanaEcho は文節を 2 かなずつに分けるので、kyouhaii は きょ / うは / いい になる
    @Test func convertsOnlyTheFocusedJapaneseClause() {
        let clauses = segmenter.clauses("kyouhaii")
        #expect(clauses.map(\.reading) == ["きょ", "うは", "いい"])
        #expect(segmenter.convertClause(clauses, at: 1, to: .katakana) == "ウハ")
        #expect(segmenter.convertClause(clauses, at: 1, to: .halfwidthKatakana) == "ｳﾊ")
        #expect(segmenter.convertClause(clauses, at: 1, to: .roman) == "uha")
        #expect(segmenter.convertClause(clauses, at: 0, to: .roman) == "kyo")
        #expect(segmenter.convertClause(clauses, at: 2, to: .fullwidthRoman) == "ｉｉ")
    }

    @Test func convertsAnEnglishClauseByItsTypedSpelling() throws {
        let clauses = segmenter.clauses("kyouhagoogle")
        let english = try #require(clauses.firstIndex { $0.kind == .english })
        #expect(segmenter.convertClause(clauses, at: english, to: .roman) == "google")
        #expect(segmenter.convertClause(clauses, at: english, to: .fullwidthRoman) == "ｇｏｏｇｌｅ")
    }

    /// きゃ の途中で文節を切ると、文節に当たる打鍵が無い。かなの文字種にはでき、英字にはできない
    @Test func refusesLettersForAClauseCutInsideOneSpelling() {
        let clauses = segmenter.resize(segmenter.clauses("kyaku"), at: 0, by: -1)
        #expect(clauses.map(\.reading) == ["き", "ゃく"])
        #expect(segmenter.convertClause(clauses, at: 0, to: .katakana) == "キ")
        #expect(segmenter.convertClause(clauses, at: 1, to: .katakana) == "ャク")
        #expect(segmenter.convertClause(clauses, at: 0, to: .roman) == nil)
        #expect(segmenter.convertClause(clauses, at: 1, to: .fullwidthRoman) == nil)
    }
}

/// KanaEcho と同じ区切りにし、表示の変換は表記を « » で囲んで、渡された左の文字列を覚える
private final class LeftRecorder: JapaneseConverting {
    private let echo = KanaEcho()
    private(set) var lefts: [String] = []

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? { echo.convert(kana: kana, context: context) }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { [] }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        lefts.append(left)
        return JapaneseDisplay(text: "«\(kana)»", clauses: [JapaneseClause(reading: kana, text: "«\(kana)»")])
    }

    func endComposition() {}
}

@Suite struct LeftContextTests {
    fileprivate let recorder = LeftRecorder()
    let segmenter: Segmenter
    /// 短い日本語区間・英語区間・長い日本語区間の順に並ぶ入力
    let input = "decwdkyouhaii"

    init() throws {
        segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: recorder)
    }

    @Test func liveTextPassesTheConvertedShortSpanToTheRight() {
        #expect(segmenter.segment(input).map(\.kind) == [.japanese, .english, .japanese])
        #expect(segmenter.liveText(input) == "でcwd«きょうはいい»")
        #expect(recorder.lefts == ["", "«で»cwd"])
    }

    @Test func clausesPassTheSameLeftAsLiveText() {
        _ = segmenter.clauses(input)
        #expect(recorder.lefts == ["", "«で»cwd"])
    }

    @Test func resizingRedisplaysTheLaterSpansWithTheNewLeft() {
        let clauses = segmenter.clauses("kyouhaiicwdde")
        #expect(clauses.map(\.kind) == [.japanese, .english, .japanese])
        let resized = segmenter.resize(clauses, at: 0, by: -1)
        #expect(resized.map(\.output) == ["«きょうはい»", "«い»", "cw", "«っで»"])
        #expect(recorder.lefts.last == "«きょうはい»«い»cw")
    }
}

@Suite struct SegmenterTests {
    let segmenter: Segmenter

    init() throws {
        segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: KanaEcho())
    }

    private func output(_ input: String, leading: Segmenter.Leading = .start) -> String {
        segmenter.segment(input, leading: leading).map(\.output).joined()
    }

    @Test(arguments: ["ga", "to", "de", "no", "ha", "wo", "ie", "a", "e"])
    func readsShortReadableSpellingsAsJapanese(input: String) {
        #expect(segmenter.segment(input).map(\.kind) == [.japanese])
    }

    @Test(arguments: ["-", "--", "-.", "xa", "kaki--", "binge-watch", ".", "a,b", "Hello."])
    func coversEveryKeystroke(input: String) {
        #expect(segmenter.segment(input).map(\.source).joined() == input)
    }

    @Test func punctuationFollowsTheSpanBefore() {
        #expect(output("kore.") == "これ。")
        #expect(output("kore,sore?") == "これ、それ？")
        #expect(output("Hello.") == "Hello.")
        #expect(output("ie~") == "いえ〜")
        #expect(output("ie!~") == "いえ！〜")
        #expect(output("cd~") == "cd~")
    }

    @Test func symbolKeysAreSymbolsWhateverSurroundsThem() {
        #expect(output("[google]") == "「google」")
        #expect(output("google/apple") == "google・apple")
        #expect(output("zhzjzkzl") == "←↓↑→")
        #expect(output("z.z/z-") == "…・〜")
        // z, は記号にしないので、英単語の後のカンマは打ったまま残る
        #expect(output("quiz,") == "quiz,")
        #expect(output("z[kagiz]") == "『かぎ』")
    }

    @Test func symbolKeysCutTheInput() {
        #expect(segmenter.segment("zhou").map(\.source) == ["zh", "ou"])
        #expect(output("zhou") == "←おう")
        #expect(output("iezlie") == "いえ→いえ")
    }

    @Test func leadingPunctuationFollowsTheTextBeforeTheCaret() {
        #expect(output(".", leading: .afterEnglish) == ".")
        #expect(output(".", leading: .afterJapanese) == "。")
        #expect(output(".", leading: .start) == "。")
        #expect(output("~", leading: .afterJapanese) == "〜")
        #expect(output("~", leading: .afterEnglish) == "~")
    }

    private func readings(_ clauses: [Clause]) -> [String] {
        clauses.map(\.reading)
    }

    @Test func splitsJapaneseSpansIntoClauses() {
        #expect(readings(segmenter.clauses("kyouhaii")) == ["きょ", "うは", "いい"])
    }

    @Test func resizingRedividesTheRestOfTheSpan() {
        let clauses = segmenter.clauses("kyouhaii")
        #expect(readings(segmenter.resize(clauses, at: 0, by: 1)) == ["きょう", "はい", "い"])
        #expect(readings(segmenter.resize(clauses, at: 0, by: -1)) == ["き", "ょう", "はい", "い"])
        #expect(readings(segmenter.resize(clauses, at: 1, by: 1)) == ["きょ", "うはい", "い"])
    }

    @Test func resizingStaysInsideTheSpan() {
        let clauses = segmenter.clauses("kyouhaii")
        let whole = segmenter.resize(clauses, at: 0, by: 4)
        #expect(readings(whole) == ["きょうはいい"])
        #expect(segmenter.resize(whole, at: 0, by: 1) == whole)
        let single = segmenter.resize(clauses, at: 0, by: -1)
        #expect(segmenter.resize(single, at: 0, by: -1) == single)
    }

    @Test func englishClausesDoNotResize() {
        let clauses = segmenter.clauses("cwdde")
        #expect(clauses.map(\.kind) == [.english, .japanese])
        #expect(segmenter.resize(clauses, at: 0, by: 1) == clauses)
    }

    @Test func committingThroughAClauseKeepsTheRestConverted() throws {
        let clauses = segmenter.clauses("kyouhaii")
        let first = try #require(segmenter.commit(clauses, through: 0))
        #expect(first.text == "きょ")
        #expect(readings(first.rest) == ["うは", "いい"])
        #expect(first.keys == "uhaii")
        let second = try #require(segmenter.commit(clauses, through: 1))
        #expect(second.keys == "ii")
        // 残りの区間の中で伸縮しても、残りの読みの外へ出ない
        #expect(readings(segmenter.resize(second.rest, at: 0, by: 1)) == ["いい"])
    }

    @Test func committingAtASpanBoundaryLeavesTheNextSpans() throws {
        let clauses = segmenter.clauses("cwdde")
        #expect(clauses.map(\.kind) == [.english, .japanese])
        let result = try #require(segmenter.commit(clauses, through: 0))
        #expect(result.text == clauses[0].output)
        #expect(result.rest == [clauses[1]])
        #expect(clauses[0].span.source + result.keys == "cwdde")
    }

    @Test func committingInsideOneSpellingIsRefused() {
        // きゃ は 1 つの綴り kya なので、き と ゃ のあいだに当たる打鍵は無い
        let clauses = segmenter.resize(segmenter.clauses("kyaku"), at: 0, by: -1)
        #expect(readings(clauses) == ["き", "ゃく"])
        #expect(segmenter.commit(clauses, through: 0) == nil)
    }
}
