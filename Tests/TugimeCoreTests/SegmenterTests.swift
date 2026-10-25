import Foundation
import Testing
@testable import TugimeCore

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
    func replaceUserDictionary(_ dictionary: UserDictionary) { base.replaceUserDictionary(dictionary) }
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

    // MARK: 日英の区切り

    @Test(arguments: ["ga", "to", "de", "no", "ha", "wo", "ie", "a", "e"])
    func readsShortReadableSpellingsAsJapanese(input: String) {
        #expect(segmenter.segment(input).map(\.kind) == [.japanese])
    }

    @Test(arguments: ["-", "--", "-.", "xa", "kaki--", "binge-watch", ".", "a,b", "Hello."])
    func coversEveryKeystroke(input: String) {
        #expect(segmenter.segment(input).map(\.source).joined() == input)
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
        #expect(output(".", leading: Segmenter.Leading("API")) == ".")
        #expect(output(".", leading: Segmenter.Leading("今日")) == "。")
        #expect(output(".", leading: .start) == "。")
        #expect(output(".", leading: Segmenter.Leading("Hello ")) == "。")
        #expect(output(".", leading: Segmenter.Leading("Hello.")) == "。")
        #expect(output("~", leading: Segmenter.Leading("今日")) == "〜")
        #expect(output("~", leading: Segmenter.Leading("API")) == "~")
    }

    /// 入力欄のカーソルより前は UTF-16 で上限まで読み、途中から読んだときは割れうる先頭の 1 文字を捨てる
    @Test func readsTheTextBeforeTheCaretUpToTheLimit() {
        func read(_ field: String) -> String {
            Segmenter.Leading(field: field).text
        }
        #expect(read("横浜から奈良") == "横浜から奈良")
        // 絵文字は UTF-16 で 2 単位なので、上限から 1 単位あふれると範囲の先頭が絵文字の途中に当たる
        let emoji = String(repeating: "😀", count: Segmenter.Leading.maxLength / 2)
        #expect(read(emoji + "y") == String(emoji.dropFirst()) + "y")
        #expect(read("") == "")
    }

    /// 入力欄の数字に続けて打っても、数字とまとめて打ったときと同じく数字に続く形で区切る
    @Test(arguments: [("3", "nin"), ("3", "kai"), ("1500", "ennharaimasu")])
    func continuesConfirmedDigitsLikeTypedDigits(digits: String, input: String) {
        let leading = Segmenter.Leading(digits)
        #expect(segmenter.segment(input, leading: leading).map(\.kind) == segmenter.segment(digits + input).dropFirst().map(\.kind))
        #expect(digits + output(input, leading: leading) == output(digits + input))
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
        base.display(kana: kana, context: context, left: left).map { shown in
            var clauses = shown.clauses
            clauses[clauses.count - 1].text += "ゑ"
            return JapaneseDisplay(text: shown.text + "ゑ", clauses: clauses)
        }
    }

    func endComposition() { base.endComposition() }
    func replaceUserDictionary(_ dictionary: UserDictionary) { base.replaceUserDictionary(dictionary) }
}

/// 打っている途中の表示が、変換して見せた区間で読みと合わないかを返す
@Suite struct LiveDisplayTests {
    @Test func flagsAConvertedSpanThatDoesNotFollowTheReading() throws {
        let segmenter = try Shared.make(RewritingConverter())
        #expect(segmenter.liveDisplay("kawacwdkyouhaii").differsFromInput)
    }
}

/// 後ろの区間の表示の変換に、前の区間の表示を左の文脈として渡す
@Suite struct LeftContextTests {
    fileprivate let recorder = LeftRecorder()
    let segmenter: Segmenter
    /// 日本語区間・英語区間・日本語区間の順に並ぶ入力
    let input = "kawacwdkyouhaii"

    init() throws {
        segmenter = try Shared.make(recorder)
    }

    /// 前の日本語区間を変換した表記と英語区間をつないだもの
    private func convertedLeft() throws -> String {
        try Shared.segmenter.get().liveText("kawa") + "cwd"
    }

    /// 入力欄のカーソルより前の文字列を、最初の区間の左の文脈にし、後ろの区間の左の文脈の前にも置く
    @Test func liveTextPassesTheTextBeforeTheCaretToEverySpan() throws {
        let left = try convertedLeft()
        _ = segmenter.liveText(input, leading: Segmenter.Leading("奈良"))
        #expect(recorder.lefts == ["奈良", "奈良" + left])
    }

    @Test func liveTextPassesTheConvertedSpanToTheRight() throws {
        let left = try convertedLeft()
        #expect(segmenter.segment(input).map(\.kind) == [.japanese, .english, .japanese])
        #expect(segmenter.liveText(input).hasPrefix(left))
        #expect(recorder.lefts == ["", left])
    }

    @Test func clausesPassTheSameLeftAsLiveText() throws {
        let left = try convertedLeft()
        _ = segmenter.clauses(input)
        #expect(recorder.lefts == ["", left])
        _ = segmenter.clauses(input, leading: Segmenter.Leading("奈良"))
        #expect(recorder.lefts.suffix(2) == ["奈良", "奈良" + left])
    }

    @Test func resizingRedisplaysTheLaterSpansWithTheNewLeft() {
        let clauses = segmenter.clauses("kyouhaiicwdde")
        #expect(clauses.map(\.kind) == [.japanese, .english, .japanese])
        let resized = segmenter.resize(clauses, at: 0, by: -1)
        #expect(readings(resized) == ["きょうはい", "い", "cwd", "で"])
        #expect(recorder.lefts.last == resized.dropLast().map(\.output).joined())
    }

    /// 伸縮した後の表示も、入力欄のカーソルより前の文字列に続けて変換する
    @Test func resizingKeepsTheTextBeforeTheCaretInTheLeft() {
        let leading = Segmenter.Leading("奈良")
        let clauses = segmenter.clauses("kyouhaiicwdde", leading: leading)
        let resized = segmenter.resize(clauses, at: 0, by: -1, leading: leading)
        #expect(readings(resized) == ["きょうはい", "い", "cwd", "で"])
        #expect(recorder.lefts.last == "奈良" + resized.dropLast().map(\.output).joined())
    }

    private func readings(_ clauses: [Clause]) -> [String] {
        clauses.map(\.reading)
    }
}
