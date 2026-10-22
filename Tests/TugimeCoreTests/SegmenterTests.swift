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
        return JapaneseReading(text: kana, value: -2 * Double(kana.count), clauses: clauses)
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { [kana] }

    func endComposition() {}
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
    }

    @Test func leadingPunctuationFollowsTheTextBeforeTheCaret() {
        #expect(output(".", leading: .afterEnglish) == ".")
        #expect(output(".", leading: .afterJapanese) == "。")
        #expect(output(".", leading: .start) == "。")
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
}
