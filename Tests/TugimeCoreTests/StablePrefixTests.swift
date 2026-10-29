import Testing
@testable import TugimeCore

@Suite struct StablePrefixTests {
    /// 続けて keystrokes 回の表示に共通する先頭を返す。覚えた表示が足りないか、未確定の打鍵が少なければ返さない
    @Test func returnsThePrefixSharedByTheRecentDisplays() {
        var stable = StablePrefix(keystrokes: 3, minimumKeys: 5, keptKeys: 1)
        stable.record("今日は朝")
        stable.record("今日は朝か")
        #expect(stable.prefix(keyCount: 10) == nil)
        stable.record("今日は浅から")
        #expect(stable.prefix(keyCount: 10) == "今日は")
        #expect(stable.prefix(keyCount: 4) == nil)
        stable.record("今日は朝から")
        #expect(stable.prefix(keyCount: 10) == "今日は")
        stable.reset()
        #expect(stable.prefix(keyCount: 10) == nil)
    }

    /// 確定するのは先頭に収まる文節までで、後ろに残す打鍵の数を守る
    @Test func commitsClausesWithinThePrefixAndKeepsKeys() throws {
        let segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: ConversionMethod.baseline.make(dictionary: TestDictionary.shared))
        let input = "kyouhaasakaraamegahutteita"
        let shown = segmenter.liveText(input)
        let result = try #require(segmenter.commit(input, leading: .start, within: shown, keeping: 5))
        #expect(!result.text.isEmpty)
        #expect(shown.hasPrefix(result.text))
        #expect(input.hasSuffix(result.keys))
        #expect(result.keys.count >= 5)
        #expect(segmenter.commit(input, leading: .start, within: shown, keeping: input.count) == nil)
        #expect(segmenter.commit(input, leading: .start, within: "", keeping: 1) == nil)
    }
}
