import Foundation
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

    @Test func everyTableKanaRoundTrips() {
        for kana in Set(table.entries.values) {
            let spelled = keys(kana)
            #expect(spelled.flatMap { table.reading(of: $0) } == kana, "\(kana) → \(spelled ?? "nil")")
        }
    }

    @Test(arguments: [
        // ん は母音・y・n の前と語末で nn、それ以外の子音の前は n
        ("けんさく", "kensaku"),
        ("こんや", "konnya"),
        ("ほんや", "honnya"),
        ("かんい", "kanni"),
        ("ほん", "honn"),
        // っ は次の子音を重ねる。重ねられない文字の前は xtu
        ("きって", "kitte"),
        ("いっしょ", "issyo"),
        ("あっ", "axtu"),
        ("っな", "xtuna"),
        // 短い綴りを選ぶ
        ("しゃ", "sya"),
        ("かれんだー", "karenda-"),
    ])
    func spellsWithTheShortestKeys(kana: String, expected: String) {
        #expect(keys(kana) == expected)
    }

    @Test func refusesKanaOutsideTheTable() {
        #expect(table.spelling(of: "（") == nil)
        #expect(table.spelling(of: "") == nil)
        #expect(table.spelling(of: "カ") == nil)
    }

    @Test func spellsPunctuationAndSymbolsAsTheirKeys() throws {
        let spelled = try #require(Segmenter.spelling(of: "ほん、「よむ」・…", table: table))
        #expect(spelled.map(\.keys).joined() == "honn,[yomu]/z.")
        #expect(spelled.map(\.kana).joined() == "ほん、「よむ」・…")
        #expect(Segmenter.spelling(of: "ほん（", table: table) == nil)
    }
}

@Suite struct ConversionMethodTests {
    @Test func specRoundTrips() throws {
        let model = FileManager.default.temporaryDirectory.appendingPathComponent("tugime-method-test.gguf")
        try Data().write(to: model)
        defer { try? FileManager.default.removeItem(at: model) }
        #expect(try ConversionMethod(spec: "azookey") == .azooKey)
        let zenzai = try ConversionMethod(spec: "zenzai:\(model.path)")
        #expect(zenzai.weight?.path == model.standardizedFileURL.path)
        #expect(try ConversionMethod(spec: zenzai.spec) == zenzai)
        let direct = try ConversionMethod(spec: "direct:\(model.path)")
        #expect(direct == .direct(weight: model.standardizedFileURL))
        #expect(try ConversionMethod(spec: direct.spec) == direct)
    }

    @Test(arguments: ["", "azookeyx", "zenzai:", "zenzai", "direct:", "direct", "llama:/a.gguf"])
    func rejectsUnknownSpecs(spec: String) {
        #expect(throws: ConversionMethod.ParseError.self) { try ConversionMethod(spec: spec) }
    }

    @Test func rejectsMissingModel() {
        #expect(throws: ConversionMethod.ParseError.self) { try ConversionMethod(spec: "zenzai:/nonexistent/model.gguf") }
    }
}
