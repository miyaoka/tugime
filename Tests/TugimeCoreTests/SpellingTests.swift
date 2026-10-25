import Testing
@testable import TugimeCore

@Suite struct SpellingTests {
    let table: RomajiTable

    init() throws {
        table = try RomajiTable.bundled()
    }

    private func keys(_ kana: String) -> String? {
        table.spelling(of: kana)?.map(\.keys).joined()
    }

    @Test(arguments: [
        // ん は常に nn
        ("けんさく", "kennsaku"),
        ("こんや", "konnya"),
        ("ほん", "honn"),
        // っ は次の子音を重ねる。重ねられない文字の前は xtu
        ("きって", "kitte"),
        ("いっしょ", "issyo"),
        ("あっ", "axtu"),
        ("っな", "xtuna"),
        // 同じかなの綴りは表で上の行（sha cha ca la より sya tya ka xa）
        ("しゃ", "sya"),
        ("かれんだー", "karennda-"),
        // 区切り方が複数あれば、使う行が表で上にある方（tcha より ttya、ye より ixe）。同じなら短い方（ki xya より kya）
        ("めっちゃ", "mettya"),
        ("いぇ", "ixe"),
        ("きゃ", "kya"),
    ])
    func spellsWithTheDefaultKeys(kana: String, expected: String) {
        #expect(keys(kana) == expected)
    }

    @Test func spellsPunctuationAndSymbolsAsTheirKeys() throws {
        let spelled = try #require(Segmenter.spelling(of: "ほん、「よむ」・…", table: table))
        #expect(spelled.map(\.keys).joined() == "honn,[yomu]/z.")
        #expect(spelled.map(\.kana).joined() == "ほん、「よむ」・…")
        #expect(Segmenter.spelling(of: "ほん（", table: table) == nil)
    }
}

@Suite struct ConversionMethodTests {
    @Test(arguments: ["", "azookeyx", "zenzai:", "zenzai", "direct:", "direct", "llama:/a.gguf"])
    func rejectsUnknownSpecs(spec: String) {
        #expect(throws: ConversionMethod.ParseError.self) { try ConversionMethod(spec: spec) }
    }
}
