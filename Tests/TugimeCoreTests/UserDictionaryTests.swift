import Foundation
import Testing
@testable import TugimeCore

@Suite struct UserDictionaryTests {
    /// 空行と # の行は読まず、同じ読みに別の表記を置ける。CRLF の改行でも同じに読む
    @Test func readsReadingAndWordPerLine() throws {
        let dictionary = try UserDictionary(contents: "# 麻雀\r\nいーそう\t一索\r\n\r\nまんず\t萬子\r\nまんず\tマンズ\r\n")
        #expect(dictionary.entries.map { [$0.reading, $0.word] } == [["いーそう", "一索"], ["まんず", "萬子"], ["まんず", "マンズ"]])
    }

    /// 誤りは 1 始まりの行番号で返し、一部だけの辞書を作らない
    @Test(arguments: [
        ("いーそう\t一索\nりゃんそう", UserDictionary.ParseError.malformedLine(2, "りゃんそう")),
        ("いーそう\t一索\t牌", .malformedLine(1, "いーそう\t一索\t牌")),
        ("\t一索", .malformedLine(1, "\t一索")),
        ("イーソウ\t一索", .readingNotHiragana(1, "イーソウ")),
        ("isou\t一索", .readingNotHiragana(1, "isou")),
        ("いーそう\t一索\n\nいーそう\t一索", .duplicateEntry(3, "いーそう\t一索")),
    ])
    func rejectsTheWholeFileOnAnError(contents: String, error: UserDictionary.ParseError) {
        #expect(throws: error) { try UserDictionary(contents: contents) }
    }
}

/// 本物の変換器に利用者の語を入れる。テストで共有する変換器（SegmenterTests の Shared）の辞書を変えないよう、別に作る
@Suite struct UserDictionaryConversionTests {
    let converter = ConversionMethod.baseline.make()

    /// 入力全体が利用者の語 1 つでも、カタカナにしただけの候補と同じ品詞なのに捨てない
    @Test func convertsAndListsTheUserWord() throws {
        converter.replaceUserDictionary(try UserDictionary(contents: "いーそう\t一索"))
        let reading = try #require(converter.convert(kana: "いーそう", context: .start))
        #expect(reading.text == "一索")
        #expect(reading.clauses.map(\.userWords) == [["一索"]])
        #expect(converter.alternatives(kana: "いーそう", context: .start).contains("一索"))
    }

    /// 前に名詞を置いて読む文脈でも、利用者の語は前に置いたものを外した文節に付く
    @Test func marksTheUserWordAfterAStandIn() throws {
        converter.replaceUserDictionary(try UserDictionary(contents: "いーそう\t一索"))
        let reading = try #require(converter.convert(kana: "いーそうをきる", context: .afterWord))
        #expect(reading.clauses.flatMap(\.userWords) == ["一索"])
        #expect(reading.text.hasPrefix("一索"))
    }

    /// 置き換えると前の語は消える。採点のセッションが前の辞書の途中の計算を使い回さない
    @Test func replacingDropsThePreviousWords() throws {
        converter.replaceUserDictionary(try UserDictionary(contents: "いーそう\t一索"))
        #expect(converter.convert(kana: "いーそう", context: .start)?.text == "一索")
        converter.replaceUserDictionary(.empty)
        let reading = try #require(converter.convert(kana: "いーそう", context: .start))
        #expect(reading.text != "一索")
        #expect(reading.clauses.flatMap(\.userWords).isEmpty)
    }
}
