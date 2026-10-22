import Testing
@testable import TugimeCore

/// かなをそのまま返す変換。評価値は長さに比例させ、区切りの規則だけを見る
private final class KanaEcho: JapaneseConverting {
    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        JapaneseReading(text: kana, value: -2 * Double(kana.count))
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
}
