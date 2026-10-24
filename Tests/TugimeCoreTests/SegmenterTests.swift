import Foundation
import Testing
@testable import TugimeCore
import TugimeCorpus

/// 本物の変換器と、それで組んだ Segmenter。作るたびに辞書と語表を読むので、全テストで共有する
private enum Shared {
    static let converter = ConversionMethod.baseline.make()
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

    /// 英語の打鍵を取り込んで日本語になった文節も、縮めれば手放した打鍵を判定し直すので元に戻る。
    /// g と o を 1 打鍵ずつ取り込んだ 今日はご は、1 かな（go）を手放して 今日は に戻る
    @Test func shrinkingAfterExtendingRestoresTheEnglishSpan() {
        let clauses = segmenter.clauses("kyouhagoogle")
        let extended = segmenter.resize(segmenter.resize(clauses, at: 0, by: 1), at: 0, by: 1)
        #expect(extended.first?.reading == "きょうはご")
        let restored = segmenter.resize(extended, at: 0, by: -1)
        #expect(restored.map(\.output) == clauses.map(\.output))
        #expect(restored.map(\.kind) == [.japanese, .english])
    }

    /// 伸ばして元に戻した文節は、区切りの選択が決めた区間に戻るので、その後の伸縮は伸ばす前と同じになる
    @Test func restoredClausesResizeAsBeforeExtending() {
        let clauses = segmenter.clauses("kyouhaiicwdde")
        let restored = segmenter.resize(segmenter.resize(clauses, at: 0, by: 1), at: 0, by: -1)
        #expect(restored.map(\.output) == clauses.map(\.output))
        #expect(segmenter.resize(restored, at: 0, by: -1).map(\.output) == segmenter.resize(clauses, at: 0, by: -1).map(\.output))
    }

    /// 区間がいくつかの文節に分かれていても、最後の文節を伸ばして元に戻せば、伸ばす前と同じに伸縮する
    @Test func restoredLastClauseOfASpanResizesAsBeforeExtending() {
        let clauses = segmenter.clauses("kyouhaiitenkidesucwdde")
        #expect(clauses.map(\.reading) == ["きょうはいい", "てんきです", "cwd", "で"])
        let restored = segmenter.resize(segmenter.resize(clauses, at: 1, by: 1), at: 1, by: -1)
        #expect(restored.map(\.output) == clauses.map(\.output))
        #expect(restored[1].candidates == clauses[1].candidates)
        #expect(segmenter.resize(restored, at: 1, by: -1).map(\.output) == segmenter.resize(clauses, at: 1, by: -1).map(\.output))
    }

    /// 前の文節の境目を変えた後でも、伸ばして元に戻した文節は伸ばす前と同じに伸縮する
    @Test func restoredClauseAfterAnotherResizeResizesAsBeforeExtending() throws {
        let shrunk = segmenter.resize(segmenter.clauses("kyouhaiitenkidesucwdde"), at: 0, by: -1)
        let index = try #require(shrunk.firstIndex { $0.reading == "てんきです" })
        let restored = segmenter.resize(segmenter.resize(shrunk, at: index, by: 1), at: index, by: -1)
        #expect(restored.map(\.output) == shrunk.map(\.output))
        #expect(segmenter.resize(restored, at: index, by: -1).map(\.output) == segmenter.resize(shrunk, at: index, by: -1).map(\.output))
    }

    /// 伸縮を続けても、文節の区間の打鍵をつなぐと元の打鍵列になる。操作は + で伸ばす、- で縮める、> と < で選ぶ文節を移す
    @Test(arguments: [
        ("kyouhaiitenkidesucwdde", "->>+--<+->+++---"),
        ("kyouhagoogledekensaku", "+++--->-+->++--"),
        ("main,dev", ">+-<-+>+--"),
        ("kyouhatokyo", "+++++----->+-"),
        ("watasihagooglewotukau", ">>+-<+++---->>-+"),
    ])
    func resizingKeepsEveryKeystroke(input: String, operations: String) {
        var clauses = segmenter.clauses(input)
        var focus = 0
        for operation in operations {
            switch operation {
            case "+": clauses = segmenter.resize(clauses, at: focus, by: 1)
            case "-": clauses = segmenter.resize(clauses, at: focus, by: -1)
            case ">": focus = min(focus + 1, clauses.count - 1)
            default: focus = max(focus - 1, 0)
            }
            var keys = ""
            var lastSpan: ClauseSpan?
            for clause in clauses where clause.span != lastSpan {
                keys += clause.span.source
                lastSpan = clause.span
            }
            #expect(keys == input, "\(operation) \(clauses.map(\.output))")
        }
    }

    /// 拗音で終わる文節も、1 つの綴り（kyo）ずつ手放すので、かなの途中で切れずに元に戻る
    @Test func shrinkingAClauseEndingInAContractedSoundRestoresTheEnglishSpan() {
        let clauses = segmenter.clauses("kyouhatokyo")
        #expect(clauses.map(\.output) == ["今日は", "tokyo"])
        let extended = segmenter.resize(clauses, at: 0, by: 5)
        #expect(extended.map(\.reading) == ["きょうはときょ"])
        let restored = segmenter.resize(segmenter.resize(extended, at: 0, by: -1), at: 0, by: -1)
        #expect(restored.map(\.output) == clauses.map(\.output))
    }

    /// 英語の文節は 1 打鍵ずつ伸縮し、日本語の区間からは 1 つの綴りずつ取り込む
    @Test func englishClausesResizeByKeystrokes() {
        let clauses = segmenter.clauses("cwdde")
        #expect(clauses.map(\.kind) == [.english, .japanese])
        #expect(segmenter.resize(clauses, at: 0, by: 1).map(\.output) == ["cwdde"])
        #expect(segmenter.resize(clauses, at: 0, by: -1).first?.output == "cw")
        #expect(segmenter.resize(segmenter.clauses("c"), at: 0, by: -1) == segmenter.clauses("c"))
    }

    /// 全体を 1 つの文字種にした文節は、区切りから文節を作り直して最初の文節を伸縮する。記号を打ったまま文節に入れない
    @Test func resizingAWholeConversionResizesTheSegmentedClauses() {
        let whole = [segmenter.wholeClause("kyouhagoogle", to: .katakana)]
        #expect(whole.map(\.kind) == [.whole])
        let segmented = segmenter.clauses("kyouhagoogle")
        #expect(segmenter.resize(whole, at: 0, by: -1) == segmenter.resize(segmented, at: 0, by: -1))
        // 最初の文節が記号で伸縮できなければ、全体の変換のまま残す
        let bracketed = [segmenter.wholeClause("[kore", to: .katakana)]
        #expect(segmenter.resize(bracketed, at: 0, by: -1) == bracketed)
        #expect(segmenter.resize(bracketed, at: 0, by: 1) == bracketed)
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

/// 本物の変換器に処理を任せ、表示の変換の末尾に読みに無いかなを足して、読みと合わない表示にする
private final class RewritingConverter: JapaneseConverting {
    private let base: JapaneseConverting = Shared.converter

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? { base.convert(kana: kana, context: context) }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { base.alternatives(kana: kana, context: context) }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        base.display(kana: kana, context: context, left: left).map { JapaneseDisplay(text: $0.text + "ゑ", clauses: $0.clauses) }
    }

    func endComposition() { base.endComposition() }
}

/// 打っている途中の表示が、変換して見せた区間で読みと合わないかを返す
@Suite struct LiveDisplayTests {
    @Test func flagsAConvertedSpanThatDoesNotFollowTheReading() throws {
        let segmenter = try Shared.make(RewritingConverter())
        #expect(segmenter.liveDisplay("kawacwdkyouhaii").differsFromInput)
    }

    /// かなのまま見せる短い区間と英語区間は、表示の変換が読みと合わなくても数えない
    @Test func ignoresSpansShownAsTyped() throws {
        let segmenter = try Shared.make(RewritingConverter())
        #expect(!segmenter.liveDisplay("kawacwd").differsFromInput)
    }

    @Test func passesADisplayThatFollowsTheReading() throws {
        #expect(try !Shared.segmenter.get().liveDisplay("kawacwdkyouhaii").differsFromInput)
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
