import Testing
@testable import TugimeCore

@Suite struct ProvisionalReadingTests {
    let table: RomajiTable

    init() throws {
        table = try RomajiTable.bundled()
    }

    @Test(arguments: [
        ("kar", "", "かr"),
        ("tyokk", "", "ちょkk"),
        ("seikakuni", "", "せいかくに"),
        // 句読点は直前がかなか日本語の記号なら日本語の記号、英字なら打ったまま
        ("nara,", "", "なら、"),
        (",", "遅そうだが", "、"),
        (",", "make", ","),
        // 記号の打鍵は前によらず記号
        ("[", "make", "「"),
        ("bn", "githu", "bん"),
        ("shsi", "githubにpu", "shし"),
    ])
    func provisionalText(keys: String, shown: String, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, after: shown, table: table) == expected)
    }

    @Test(arguments: [
        // 打ちかけの子音は表示から外して読み直す
        ("g", "g", "", 1),
        ("github", "github", "githu", 1),
        ("githubにpush", "githubnipush", "githubにpu", 2),
        ("してh", "siteh", "して", 1),
        // 単独の n を読んだ「ん」も外す
        ("幕張ん", "makuharin", "幕張", 1),
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

    @Test(arguments: [
        // 打ちかけの n が表示の中に入っていて外せない
        ("点", "ten"),
    ])
    func cannotSplit(shown: String, keys: String) {
        #expect(Segmenter.splitPending(shown, typed: keys) == nil)
    }
}
