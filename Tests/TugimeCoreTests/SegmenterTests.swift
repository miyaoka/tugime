import Foundation
import Testing
@testable import TugimeCore
import TugimeCorpus

/// 本物の変換器と、それで組んだ Segmenter。作るたびに辞書と語表を読むので、全テストで共有する
private enum Shared {
    static let converter = AzooKeyConverter(zenzaiWeight: nil)
    static let table = Result { try RomajiTable.bundled() }
    static let english = Result { try EnglishModel.bundled() }
    static let segmenter = Result { try make(converter) }

    static func make(_ japanese: JapaneseConverting) throws -> Segmenter {
        try Segmenter(table: table.get(), english: english.get(), japanese: japanese)
    }
}

/// 本物の変換器に処理を任せ、表示の変換に渡された左の文字列を記録する
private final class LeftRecorder: JapaneseConverting {
    private let base: JapaneseConverting = Shared.converter
    private(set) var lefts: [String] = []

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? { base.convert(kana: kana, context: context) }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { base.alternatives(kana: kana, context: context) }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        lefts.append(left)
        return base.display(kana: kana, context: context, left: left)
    }

    func endComposition() { base.endComposition() }
}

@Suite struct SegmenterTests {
    let segmenter: Segmenter

    init() throws {
        segmenter = try Shared.segmenter.get()
    }

    private func output(_ input: String, leading: Segmenter.Leading = .start) -> String {
        segmenter.segment(input, leading: leading).map(\.output).joined()
    }

    private func readings(_ clauses: [Clause]) -> [String] {
        clauses.map(\.reading)
    }

    // MARK: 例文集

    /// 例文集の全件が、表示する文字列と一致する
    @Test func matchesEveryCorpusExample() throws {
        let path = URL(filePath: #filePath).appending(path: "../../../corpus/examples.tsv").standardized.path
        let examples = try CorpusExample.load(path: path)
        #expect(!examples.isEmpty)
        for example in examples {
            #expect(segmenter.displayText(example.input) == example.expected, "\(example.input)")
        }
    }

    // MARK: 日英の区切り

    @Test(arguments: ["ga", "to", "de", "no", "ha", "wo", "ie", "a", "e"])
    func readsShortReadableSpellingsAsJapanese(input: String) {
        #expect(segmenter.segment(input).map(\.kind) == [.japanese])
    }

    @Test(arguments: ["-", "--", "-.", "xa", "kaki--", "binge-watch", ".", "a,b", "Hello."])
    func coversEveryKeystroke(input: String) {
        #expect(segmenter.segment(input).map(\.source).joined() == input)
    }

    @Test(arguments: ["hee", "sugoi", "kawaii"])
    func readsRomanizedJapaneseAsJapanese(input: String) {
        #expect(segmenter.segment(input).map(\.kind) == [.japanese])
    }

    /// 採点する読みの長さを超える、読めて英語の語でない綴りも、日本語区間の連なりとして採れるので英語にしない
    @Test(arguments: ["yototesahapogatogonugo", "sobazuhihegehewado", "rimigezagumanorodaboho"])
    func readsLongReadableSpellingsAsJapanese(input: String) {
        #expect(segmenter.segment(input).allSatisfy { $0.kind == .japanese })
    }

    /// 長音を省いた綴りは利用者の綴りでその語の読みにならないので、英語の語として残る
    @Test func keepsSpellingsWithoutTheLongVowelAsEnglish() {
        #expect(segmenter.segment("tokyo").map(\.kind) == [.english])
    }

    // MARK: 句読点と記号

    @Test func punctuationFollowsTheSpanBefore() {
        #expect(output("kore.") == "これ。")
        #expect(output("kore,sore?") == "これ、それ？")
        #expect(output("Hello.") == "Hello.")
        #expect(output("hee~") == "へえ〜")
        #expect(output("sugoi!~") == "すごい！〜")
        #expect(output("cd~") == "cd~")
        #expect(output("quiz,quote,") == "quiz,quote,")
    }

    @Test func leadingPunctuationFollowsTheTextBeforeTheCaret() {
        #expect(output(".", leading: .afterEnglish) == ".")
        #expect(output(".", leading: .afterJapanese) == "。")
        #expect(output(".", leading: .start) == "。")
        #expect(output("~", leading: .afterJapanese) == "〜")
        #expect(output("~", leading: .afterEnglish) == "~")
    }

    @Test func symbolKeysAreSymbolsWhateverSurroundsThem() {
        #expect(output("[google]wokensaku") == "「google」を検索")
        #expect(output("google/apple") == "google・apple")
        #expect(output("zhzjzkzl") == "←↓↑→")
        #expect(output("z.z/z-") == "…・〜")
        #expect(output("10z-20") == "10〜20")
        let bracketed = segmenter.segment("z[kagiz]")
        #expect(bracketed.map(\.kind) == [.punctuation, .japanese, .punctuation])
        #expect(bracketed.map(\.reading) == ["『", "かぎ", "』"])
    }

    @Test func symbolKeysCutTheInput() {
        #expect(segmenter.segment("zhou").map(\.source) == ["zh", "ou"])
        #expect(output("sorezlkore") == "それ→これ")
        // 記号の後ろは文の途中として読めるので、助詞が続く
        #expect(output("sorezlmade") == "それ→まで")
        #expect(output("[google]made") == "「google」まで")
    }

    // MARK: 文節

    @Test func splitsJapaneseSpansIntoClauses() {
        #expect(readings(segmenter.clauses("kyouhaiitenkidesu")) == ["きょうはいい", "てんきです"])
    }

    @Test func resizingRedividesTheRestOfTheSpan() {
        let clauses = segmenter.clauses("kyouhaiitenkidesu")
        #expect(readings(segmenter.resize(clauses, at: 0, by: -1)) == ["きょうはい", "い", "てんきです"])
        #expect(readings(segmenter.resize(clauses, at: 0, by: 1)) == ["きょうはいいて", "んきです"])
        #expect(readings(segmenter.resize(clauses, at: 1, by: -1)) == ["きょうはいい", "てんきで", "す"])
    }

    @Test func japaneseClausesKeepOneKana() {
        let single = segmenter.resize(segmenter.clauses("kyouhaiitenkidesu"), at: 1, by: -4)
        #expect(readings(single) == ["きょうはいい", "て", "んきです"])
        #expect(segmenter.resize(single, at: 1, by: -1) == single)
    }

    /// 日本語の文節は、区間の終わりを越えて英語の打鍵を取り込める。読めない打鍵を含めば英語の文節になり、縮めれば戻る
    @Test func resizingCrossesIntoTheEnglishSpan() throws {
        let clauses = segmenter.clauses("main,dev")
        #expect(clauses.map(\.output) == ["main,", "で", "v"])
        let extended = segmenter.resize(clauses, at: 1, by: 1)
        #expect(extended.map(\.output) == ["main,", "dev"])
        #expect(extended.map(\.kind) == [.english, .english])
        #expect(try #require(segmenter.commit(extended, through: 0)).keys == "dev")
        #expect(segmenter.resize(extended, at: 1, by: -1).map(\.output) == ["main,", "で", "v"])
    }

    /// 英語の文節は 1 打鍵ずつ伸縮し、日本語の区間からは 1 つの綴りずつ取り込む
    @Test func englishClausesResizeByKeystrokes() {
        let clauses = segmenter.clauses("cwdde")
        #expect(clauses.map(\.kind) == [.english, .japanese])
        #expect(segmenter.resize(clauses, at: 0, by: 1).map(\.output) == ["cwdde"])
        #expect(segmenter.resize(clauses, at: 0, by: -1).first?.output == "cw")
        #expect(segmenter.resize(segmenter.clauses("c"), at: 0, by: -1) == segmenter.clauses("c"))
    }

    /// 句読点と記号は取り込まない
    @Test func resizingStopsAtPunctuation() {
        let clauses = segmenter.clauses("kore,sore")
        #expect(clauses.map(\.kind) == [.japanese, .punctuation, .japanese])
        #expect(segmenter.resize(clauses, at: 0, by: 1) == clauses)
        #expect(segmenter.resize(clauses, at: 1, by: 1) == clauses)
    }

    @Test func convertsOnlyTheFocusedJapaneseClause() {
        let clauses = segmenter.clauses("kyouhaiitenkidesu")
        #expect(segmenter.convertClause(clauses, at: 1, to: .katakana) == "テンキデス")
        #expect(segmenter.convertClause(clauses, at: 1, to: .halfwidthKatakana) == "ﾃﾝｷﾃﾞｽ")
        #expect(segmenter.convertClause(clauses, at: 1, to: .roman) == "tenkidesu")
        #expect(segmenter.convertClause(clauses, at: 1, to: .fullwidthRoman) == "ｔｅｎｋｉｄｅｓｕ")
        #expect(segmenter.convertClause(clauses, at: 0, to: .hiragana) == "きょうはいい")
    }

    @Test func convertsAnEnglishClauseByItsTypedSpelling() throws {
        let clauses = segmenter.clauses("kyouhagoogle")
        let english = try #require(clauses.firstIndex { $0.kind == .english })
        #expect(segmenter.convertClause(clauses, at: english, to: .roman) == "google")
        #expect(segmenter.convertClause(clauses, at: english, to: .fullwidthRoman) == "ｇｏｏｇｌｅ")
    }

    @Test func readsAnEnglishClauseWithSpacesWordByWord() throws {
        let clauses = segmenter.clauses("make wojikkousuru")
        let english = try #require(clauses.firstIndex { $0.kind == .english })
        #expect(clauses[english].span.source == "make ")
        #expect(segmenter.convertClause(clauses, at: english, to: .hiragana) == "まけ ")
        #expect(clauses[english].candidates.contains("まけ "))
        #expect(clauses[english].candidates.contains("負け "))
        #expect(segmenter.convertWhole("make ", to: .katakana) == "マケ ")
    }

    @Test func keepsUnreadableWordsOfAnEnglishClauseAsTyped() throws {
        let clauses = segmenter.clauses("ai agentwotukau")
        let english = try #require(clauses.firstIndex { $0.kind == .english })
        #expect(clauses[english].span.source == "ai agent")
        #expect(segmenter.convertClause(clauses, at: english, to: .hiragana) == "あい agent")
        #expect(segmenter.convertWhole("dark mode", to: .hiragana) == "dark もで")
        #expect(segmenter.convertWhole("tsrs content", to: .hiragana) == "tsrs content")
    }

    // MARK: 途中の確定

    @Test func committingThroughAClauseKeepsTheRestConverted() throws {
        let clauses = segmenter.resize(segmenter.clauses("kyouhaiitenkidesu"), at: 0, by: -2)
        #expect(readings(clauses) == ["きょうは", "いい", "てんきです"])
        let first = try #require(segmenter.commit(clauses, through: 0))
        #expect(first.text == clauses[0].output)
        #expect(readings(first.rest) == ["いい", "てんきです"])
        #expect(first.keys == "iitenkidesu")
        let second = try #require(segmenter.commit(clauses, through: 1))
        #expect(second.keys == "tenkidesu")
        // 残りの区間の中で伸縮しても、残りの読みの外へ出ない
        #expect(readings(segmenter.resize(second.rest, at: 0, by: 1)) == ["てんきです"])
    }

    @Test func committingAtASpanBoundaryLeavesTheNextSpans() throws {
        let clauses = segmenter.clauses("cwdde")
        let result = try #require(segmenter.commit(clauses, through: 0))
        #expect(result.text == "cwd")
        #expect(result.rest == [clauses[1]])
        #expect(result.keys == "de")
    }

    /// きゃ は 1 つの綴り kya なので、き と ゃ のあいだに当たる打鍵は無い。かなの文字種にはでき、英字にはできない
    @Test func refusesLettersForACutInsideOneSpelling() {
        let clauses = segmenter.resize(segmenter.resize(segmenter.clauses("kyaku"), at: 0, by: -1), at: 0, by: -1)
        #expect(readings(clauses) == ["き", "ゃく"])
        #expect(segmenter.convertClause(clauses, at: 0, to: .katakana) == "キ")
        #expect(segmenter.convertClause(clauses, at: 1, to: .katakana) == "ャク")
        #expect(segmenter.convertClause(clauses, at: 0, to: .roman) == nil)
        #expect(segmenter.convertClause(clauses, at: 1, to: .fullwidthRoman) == nil)
        #expect(segmenter.commit(clauses, through: 0) == nil)
    }
}

/// 後ろの区間の表示の変換に、前の区間の表示を左の文脈として渡す
@Suite struct LeftContextTests {
    fileprivate let recorder = LeftRecorder()
    let segmenter: Segmenter
    /// 短い日本語区間・英語区間・長い日本語区間の順に並ぶ入力。短い区間はかなのまま見せるが、変換すると かわ は 川 になる
    let input = "kawacwdkyouhaii"

    init() throws {
        segmenter = try Shared.make(recorder)
    }

    /// 短い区間を変換した表記と英語区間をつないだもの。かなのままの表示（かわcwd）とは違う
    private func convertedLeft() throws -> String {
        let left = try Shared.segmenter.get().displayText("kawa") + "cwd"
        #expect(left != "かわcwd")
        return left
    }

    @Test func liveTextPassesTheConvertedShortSpanToTheRight() throws {
        let left = try convertedLeft()
        #expect(segmenter.segment(input).map(\.kind) == [.japanese, .english, .japanese])
        #expect(segmenter.liveText(input).hasPrefix("かわcwd"))
        #expect(recorder.lefts == ["", left])
    }

    @Test func clausesPassTheSameLeftAsLiveText() throws {
        let left = try convertedLeft()
        _ = segmenter.clauses(input)
        #expect(recorder.lefts == ["", left])
    }

    @Test func resizingRedisplaysTheLaterSpansWithTheNewLeft() {
        let clauses = segmenter.clauses("kyouhaiicwdde")
        #expect(clauses.map(\.kind) == [.japanese, .english, .japanese])
        let resized = segmenter.resize(clauses, at: 0, by: -1)
        #expect(readings(resized) == ["きょうはい", "い", "cwd", "で"])
        #expect(recorder.lefts.last == resized.dropLast().map(\.output).joined())
    }

    private func readings(_ clauses: [Clause]) -> [String] {
        clauses.map(\.reading)
    }
}
