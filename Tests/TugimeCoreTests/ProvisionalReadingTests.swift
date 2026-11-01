import Testing
@testable import TugimeCore

@Suite struct ProvisionalReadingTests {
    let table: RomajiTable

    init() throws {
        table = try RomajiTable.bundled()
    }

    private func display(_ text: String) -> Segmenter.LiveDisplay {
        Segmenter.LiveDisplay(text: text, differsFromInput: false)
    }

    @Test(arguments: [
        ("kar", true, "かr"),
        ("tyokk", true, "ちょkk"),
        ("seikakuni", true, "せいかくに"),
        // 句読点は直前が日本語なら日本語の記号、英字なら打ったまま
        ("nara,", true, "なら、"),
        (",", true, "、"),
        (",", false, ","),
        // 記号の打鍵は前によらず記号
        ("[", false, "「"),
        ("shsi", false, "shし"),
    ])
    func provisionalText(keys: String, afterJapanese: Bool, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, afterJapanese: afterJapanese, inJapanese: false, table: table) == expected)
    }

    /// 日本語区間の頭の末尾の n は な行 の途中なので打ったまま。区間の途中と nn は「ん」
    @Test(arguments: [
        ("n", false, "n"),
        ("bn", false, "bn"),
        ("ka,n", false, "か、n"),
        ("n", true, "ん"),
        ("kon", false, "こん"),
        ("nn", false, "ん"),
    ])
    func keepsPendingNAtTheHeadOfJapanese(keys: String, inJapanese: Bool, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, afterJapanese: true, inJapanese: inJapanese, table: table) == expected)
    }

    @Test(arguments: [
        // 打ちかけの子音は表示から外して読み直す
        ("g", "g", "", 1),
        ("github", "github", "githu", 1),
        ("githubにpush", "githubnipush", "githubにpu", 2),
        ("してh", "siteh", "して", 1),
        // 単独の n を読んだ「ん」と、英語の区間に打ったまま出た n も外す
        ("幕張ん", "makuharin", "幕張", 1),
        ("python", "python", "pytho", 1),
        // 母音や nn で終われば外さない
        ("設定を", "setteiwo", "設定を", 0),
        ("本", "honn", "本", 0),
        ("感k", "kannk", "感", 1),
    ])
    func splitsPending(shown: String, keys: String, kept: String, pending: Int) throws {
        let split = try #require(Segmenter.splitPending(shown, typed: keys))
        #expect(split.kept == kept)
        #expect(split.pending == pending)
    }

    @Test func cannotSplitWhenPendingIsInsideAWord() {
        #expect(Segmenter.splitPending("点", typed: "ten") == nil)
    }

    @Test(arguments: [
        // 同じ打鍵列の変換が届いていればそれ
        ("githubni", [("githubni", "githubに")], "", "githubに"),
        // 先頭に当たる最新の変換から打ちかけを外し、後の打鍵とまとめて読む
        ("githubni", [("github", "github")], "", "githubに"),
        ("gi", [("g", "g")], "", "ぎ"),
        ("teno", [("te", "て"), ("ten", "点")], "", "ての"),
        // Backspace で前の打鍵列に戻ったときも、届いている変換を使う
        ("make", [("make", "make"), ("makes", "makes")], "", "make"),
        // 届いていなければ打鍵列全体を読む。先頭の句読点は入力欄の直前で決める
        (",", [], "今日は", "、"),
        (",", [], "make", ","),
    ])
    func liveDisplay(keys: String, converted: [(String, String)], before: String, expected: String) {
        let shown = Segmenter.liveDisplay(
            of: keys, converted: converted.map { ($0.0, display($0.1)) }, leading: Segmenter.Leading(field: before), table: table
        )
        #expect(shown.text == expected)
    }
}
