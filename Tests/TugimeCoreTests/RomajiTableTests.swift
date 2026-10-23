import Testing
@testable import TugimeCore

/// 区間全体を読み切ったときのかな。読めなければ nil
private func read(_ input: String) throws -> String? {
    try RomajiTable.bundled().reading(of: input)
}

@Suite struct RomajiTableTests {
    @Test(arguments: [
        ("kensaku", "けんさく"),
        ("konnya", "こんや"),
        ("konya", "こにゃ"),
        ("kitte", "きって"),
        ("ttu", "っつ"),
        ("xtu", "っ"),
        ("xya", "ゃ"),
        ("sitituhuji", "しちつふじ"),
        ("syatyaja", "しゃちゃじゃ"),
        ("hanadi", "はなぢ"),
        ("karenda-", "かれんだー"),
        ("thidhi", "てぃでぃ"),
    ])
    func readsUserSpelling(input: String, kana: String) throws {
        #expect(try read(input) == kana)
    }

    @Test(arguments: [
        // 語末の単独の n は読まない
        "main",
        // このユーザーが使わない綴り
        "shi", "chi", "tsu", "fu", "zi", "sha", "cha", "jya", "zya", "la", "ltu", "ca", "qa",
        // 「っ」「ん」の後ろに綴りが続かない
        "kk", "kan",
        // 大文字は表に無い
        "Ka",
    ])
    func rejectsWhatTheUserNeverTypes(input: String) throws {
        #expect(try read(input) == nil)
    }

    @Test func readsEachWordAndKeepsTheSpaces() throws {
        let table = try RomajiTable.bundled()
        #expect(table.readingKeepingSpaces(of: "make ") == "まけ ")
        #expect(table.readingKeepingSpaces(of: " dame desu") == " だめ です")
        #expect(table.readingKeepingSpaces(of: "dark mode") == nil)
        #expect(table.readingKeepingSpaces(of: " ") == nil)
    }

    @Test func doesNotReadNBeforeYOrN() throws {
        // n の後ろが y なら「にゃ」と読み、単独の「ん」にはしない
        #expect(try read("nya") == "にゃ")
        #expect(try read("nnn") == nil)
    }
}
