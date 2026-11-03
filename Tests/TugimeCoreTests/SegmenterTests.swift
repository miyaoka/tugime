import Foundation
import Testing
@testable import TugimeCore


/// 本物の変換器に処理を任せ、表示の変換に渡された読みと左の文字列を呼ばれた順に記録する
private final class DisplayRecorder: JapaneseConverting {
    private let base: JapaneseConverting = Shared.converter
    private(set) var kanas: [String] = []
    private(set) var lefts: [String] = []

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading { base.convert(kana: kana, context: context) }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { base.alternatives(kana: kana, context: context) }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay {
        kanas.append(kana)
        lefts.append(left)
        return base.display(kana: kana, context: context, left: left)
    }

    func endComposition() { base.endComposition() }
    func replaceUserWords(_ words: [UserWord]) { base.replaceUserWords(words) }
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

    /// 区間の読みをつないだもの。日本語区間はかな、英語区間は打鍵、記号は記号の形。どの漢字にするかは辞書が決めるので含まない
    private func reading(_ input: String, leading: Segmenter.Leading = .start) -> String {
        segmenter.segment(input, leading: leading).map(\.reading).joined()
    }

    // MARK: 日英の区切り

    @Test(arguments: ["ga", "to", "de", "no", "ha", "wo", "ie", "a", "e"])
    func readsShortReadableSpellingsAsJapanese(input: String) {
        #expect(segmenter.segment(input).map(\.kind) == [.japanese])
    }

    /// 数字と英字が混ざる綴りは、読めても日本語に寄せず、英語の区間も候補として採点で比べる。どちらが勝つかは変換の自然さで決まる
    @Test(arguments: ["3i", "3a", "i18n"])
    func comparesDigitsAndLettersAsEnglishToo(input: String) {
        #expect(segmenter.candidates(input).contains { $0.start == 0 && $0.end == input.count && $0.segment.kind == .english })
    }

    /// 長い日本語の読みは、途中で切らずに 1 つの日本語区間としても採点で比べる
    @Test(arguments: ["abaiteikunodarou", "setteisareteori"])
    func comparesALongReadingAsOneJapaneseSpan(input: String) {
        #expect(segmenter.candidates(input).contains { $0.start == 0 && $0.end == input.count && $0.segment.kind == .japanese })
    }

    /// 数字は日本語区間の読みに入るので、数字をはさむ日本語は 1 つの区間になり、後ろの語も前の語の変換の手がかりになる
    @Test func keepsJapaneseAroundDigitsInOneSpan() {
        let segments = segmenter.segment("3kamo4kamoyasumu")
        #expect(segments.map(\.kind) == [.japanese])
        #expect(segments.map(\.reading) == ["3かも4かもやすむ"])
    }

    /// 数字にはさまれた . , : と、数字の直後の - は、数の一部として打ったまま残す。ほかの記号は直前の区間に従う
    @Test(arguments: [
        ("3.14", "3.14"), ("1,000enn", "1,000えん"), ("10:30kara", "10:30から"), ("kakakuha1500.", "かかくは1500。"), ("kyouha3.14.", "きょうは3.14。"), ("dennwaha0120-345-678,ato", "でんわは0120-345-678、あと"),
        ("2026-11-03", "2026-11-03"), ("03-1234-5678", "03-1234-5678"), ("3-5ninn", "3-5にん"), ("3~5nichi", "3〜5にち"),
    ])
    func keepsPunctuationBetweenDigitsAsTyped(input: String, expected: String) {
        #expect(reading(input) == expected)
    }

    /// 末尾に打った単独の n は、次に打つまで な行 か「ん」かが決まらないので打ったまま。nn と、後ろに句読点が続く n は「ん」。
    /// n の手前に日本語の語があるときは、PendingNReadingTests が手前の読みを確かめる
    @Test(arguments: [("n", "n"), ("3n", "3n"), ("githubn", "githubn"), ("kore,n", "、n"), ("nn", "ん"), ("n.", "ん。")])
    func keepsAPendingNAsTyped(input: String, expected: String) {
        let shown = segmenter.liveText(input)
        #expect(shown.hasSuffix(expected), "\(shown)")
        #expect(!shown.dropLast(expected.count).hasSuffix("n"), "\(shown)")
    }

    /// 語の途中でも、末尾の単独の n は打ったまま見せる。nn で終われば「ん」まで読む。綴りの組の一部の n（xn）は単独の n ではない
    @Test func showsAPendingNAsTypedInsideAWord() {
        #expect(segmenter.liveText("konnn").hasSuffix("n"))
        #expect(!segmenter.liveText("konn").hasSuffix("n"))
        #expect(!segmenter.liveText("xn").hasSuffix("n"))
        #expect(!segmenter.liveText("kaxn").hasSuffix("n"))
    }

    /// 文節に区切るときは n を外さず「ん」まで読む（nihon の候補に 日本）
    @Test func readsAPendingNAsNWhenSplittingIntoClauses() {
        #expect(segmenter.clauses("nihon").map(\.reading).joined() == "にほん")
    }

    /// 文の頭で末尾に打った 1 かなは、続けて打つ語の先頭なので変換せずにかなのまま見せる。候補では語を選べる
    @Test func showsALoneKanaAtTheSentenceHeadAsKana() throws {
        #expect(segmenter.liveText("ki") == "き")
        #expect(segmenter.liveText("sorede,ke").hasSuffix("、け"))
        #expect(segmenter.liveText("ki", leading: Segmenter.Leading("今日は雨だった。")) == "き")
        // 入力欄の前が文の途中でも、入力の先頭なら位置で決める
        #expect(segmenter.liveText("ki", leading: Segmenter.Leading("今日は")) == "き")
        let clause = try #require(segmenter.clauses("ki").first)
        #expect(clause.candidates.first == "き")
        // かなと打鍵のほかに、1 かなの語がある
        #expect(clause.candidates.contains { !["き", "キ", "ki"].contains($0) })
    }

    @Test(arguments: ["-", "--", "-.", "xa", "kaki--", "binge-watch", ".", "a,b", "Hello."])
    func coversEveryKeystroke(input: String) {
        #expect(segmenter.segment(input).map(\.source).joined() == input)
    }

    /// 長く読めて英語の語でない綴りは、日本語として採れるので英語にしない
    @Test(arguments: ["yototesahapogatogonugo", "sobazuhihegehewado", "rimigezagumanorodaboho"])
    func readsLongReadableSpellingsAsJapanese(input: String) {
        #expect(segmenter.segment(input).allSatisfy { $0.kind == .japanese })
    }

    /// 促音の形の数詞（ひゃっ・じゅっ）を含む読みも日本語区間として採り、途中に英字を残さない
    @Test(arguments: [("hyappoyuzuru", "ひゃっぽゆずる"), ("sorehagojuppohyappo", "それはごじゅっぽひゃっぽ")])
    func readsGeminatedNumeralsAsJapanese(input: String, expected: String) {
        #expect(segmenter.segment(input).allSatisfy { $0.kind == .japanese })
        #expect(reading(input) == expected)
    }

    /// 長音を省いた綴りは利用者の綴りでその語の読みにならないので、英語の語として残る
    @Test func keepsSpellingsWithoutTheLongVowelAsEnglish() {
        #expect(segmenter.segment("tokyo").map(\.kind) == [.english])
    }

    // MARK: 句読点と記号

    @Test func punctuationFollowsTheSpanBefore() {
        #expect(reading("kore.") == "これ。")
        #expect(reading("kore,sore?") == "これ、それ？")
        #expect(output("Hello.") == "Hello.")
        #expect(reading("hee~") == "へえ〜")
        #expect(reading("sugoi!~") == "すごい！〜")
        #expect(output("cd~") == "cd~")
        #expect(output("quiz,quote,") == "quiz,quote,")
    }

    /// 丸括弧・コロン・等号も句読点と同じく、直前が日本語なら全角、英語なら打ったまま
    @Test func bracketsColonAndEqualsFollowTheSpanBefore() {
        #expect(reading("kore(sore)") == "これ（それ）")
        #expect(reading("kore:sore") == "これ：それ")
        #expect(output("https:") == "https:")
        #expect(reading("kore=sore") == "これ＝それ")
        #expect(output("x=1") == "x=1")
        #expect(output("(", leading: Segmenter.Leading("今日")) == "（")
        #expect(output("(", leading: Segmenter.Leading("API")) == "(")
    }

    /// 閉じ括弧は、入れ子を数えて組になる開き括弧の形にそろえる
    @Test func closingBracketsFollowTheirOpeners() {
        #expect(reading("kore(github)") == "これ（github）")
        #expect(reading("github(kore)") == "github(これ)")
        #expect(reading("(kore(sore),f(x))") == "（これ（それ）、f(x)）")
        // 組になる開き括弧が入力欄の前にあれば、その形にする
        #expect(output("github)", leading: Segmenter.Leading("これは（")) == "github）")
        #expect(reading("kore)", leading: Segmenter.Leading("f(")) == "これ)")
    }

    /// 閉じ括弧の後ろは、そろえた形の後として区切る。全角の後は文の頭、半角の後は英語の後
    @Test func punctuationAfterAClosingBracketFollowsItsForm() {
        #expect(reading("kore(github).") == "これ（github）。")
        #expect(reading("github(kore).") == "github(これ).")
    }

    /// 英語の区間の末尾で打ったままにした句読点は、日本語の記号を候補で選べる。途中の句読点は変えない
    @Test func punctuationAfterEnglishOffersTheJapaneseMark() {
        let clauses = segmenter.clauses(".", leading: Segmenter.Leading("github"))
        #expect(clauses.map(\.output) == ["."])
        #expect(clauses[0].candidates.contains("。"))
        let english = segmenter.clauses("vue.js")
        #expect(english.map(\.output) == ["vue.js"])
        #expect(!english[0].candidates.contains("vue。js"))
    }

    /// 括弧の候補を選び直すと、組になる括弧だけの文節も同じ形になる
    @Test func choosingABracketPairsItsPartner() throws {
        let clauses = segmenter.clauses("kore(sore)")
        let open = try #require(clauses.firstIndex { $0.output == "（" })
        let close = try #require(clauses.firstIndex { $0.output == "）" })
        let paired = Clause.selecting(try #require(clauses[open].candidates.firstIndex(of: "(")), at: open, in: clauses)
        #expect(paired[open].output == "(")
        #expect(paired[close].output == ")")
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

    /// 入力欄が前の文字列を返さないアプリでも、tugime で確定した文字列の続きは、入力欄を読めるアプリと同じ結果になる
    @Test func continuesOwnCommitsWhenTheFieldReturnsNothing() {
        var context = LeadingContext()
        context.didCommit("API")
        let leading = context.leading(field: .start)
        #expect(leading == Segmenter.Leading("API"))
        #expect(output(".", leading: leading) == ".")
        // 続けて確定した文字列はつなげ、入力欄から読むときと同じ上限までにする
        context.didCommit("今日")
        #expect(context.leading(field: .start).text == "API今日")
        let long = String(repeating: "あ", count: Segmenter.Leading.maxLength)
        context.didCommit(long)
        #expect(context.leading(field: .start) == Segmenter.Leading(field: "API今日" + long))
    }

    /// 入力欄が返す前の文字列は確定した文字列より優先し、確定した文字列はアプリにキーを渡すと捨てる
    @Test func forgetsOwnCommitsWhenTheFieldMayHaveChanged() {
        var context = LeadingContext()
        context.didCommit("API")
        #expect(context.leading(field: Segmenter.Leading("今日")).text == "今日")
        context.didCommit("API")
        context.forgetCommits()
        #expect(context.leading(field: .start) == .start)
    }

    /// 確定した文字列を返したことのある入力欄で前に何も無いのは、カーソルを先頭や別の欄へ動かしたときなので文頭にする
    @Test func trustsAnEmptyFieldThatHasReturnedOwnCommits() {
        var context = LeadingContext()
        context.didCommit("API")
        #expect(context.leading(field: Segmenter.Leading("README の API")).text == "README の API")
        context.didCommit("です")
        #expect(context.leading(field: .start) == .start)
    }

    /// 入力欄が返した文字列が確定した文字列と食い違っても、その後に同じ欄で確定した文字列を返せば、空の入力欄を文頭にする
    @Test func trustsAnEmptyFieldAfterReadingAnotherFieldOnce() {
        var context = LeadingContext()
        context.didCommit("API")
        #expect(context.leading(field: Segmenter.Leading("hello")).text == "hello")
        context.didCommit("x")
        #expect(context.leading(field: Segmenter.Leading("hellox")).text == "hellox")
        context.didCommit("y")
        #expect(context.leading(field: .start) == .start)
    }

    /// 入力欄の数字に続けて打っても、数字とまとめて打ったときと同じく数字に続く形で区切る。数字の後の句読点も同じ形になる
    @Test(arguments: [("3", "nin"), ("3", "kai"), ("1500", "ennharaimasu"), ("1500", "."), ("html5", "."), ("3", ".14"), ("1", ",000enn"), ("2026", "-11-03"), ("3.14", ".")])
    func continuesConfirmedDigitsLikeTypedDigits(digits: String, input: String) {
        let leading = Segmenter.Leading(digits)
        #expect(digits + output(input, leading: leading) == output(digits + input))
    }

    @Test func symbolKeysAreSymbolsWhateverSurroundsThem() {
        #expect(reading("[google]wokensaku") == "「google」をけんさく")
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
        #expect(reading("sorezlkore") == "それ→これ")
        // 記号の後ろは文の途中として読めるので、助詞が続く
        #expect(reading("sorezlmade") == "それ→まで")
        #expect(reading("[google]made") == "「google」まで")
    }

    // MARK: 文節

    /// 伸縮を続けても、文節の区間の打鍵をつなぐと元の打鍵列になる。操作は + で伸ばす、- で縮める、> と < で選ぶ文節を移す
    @Test(arguments: [
        ("kyouhaiitenkidesucwdde", "->>+--<+->+++---"),
        ("kyouhagoogledekensaku", "+++--->-+->++--"),
        ("main,dev", ">+-<-+>+--"),
        ("kyouhatokyo", "+++++----->+-"),
        ("watasihagooglewotukau", ">>+-<+++---->>-+"),
        ("kyouha(cafe)desu", ">+++++-----<++>+-"),
        ("kore,are,sore", "+++>-<--->+"),
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

    /// 括弧の文節を伸ばすと、括弧と中の語を 1 つの日本語の文節にして変換する。縮めると元の区切りに戻る
    @Test func resizingAcrossBracketsConvertsThemAsOneClause() {
        let original = segmenter.clauses("(cafe)")
        #expect(original.map(\.kind) == [.punctuation, .english, .punctuation])
        #expect(readings(original) == ["（", "cafe", "）"])
        var clauses = original
        for _ in 0..<6 { clauses = segmenter.resize(clauses, at: 0, by: 1) }
        #expect(clauses.count == 1)
        #expect(clauses[0].kind == .japanese)
        #expect(clauses[0].reading == "（かふぇ）")
        // かなと打ったままの形は規則で決まる。変換した表記は点で決まるので書かない
        #expect(Set(["（かふぇ）", "(cafe)"]).isSubset(of: clauses[0].candidates))
        for _ in 0..<6 { clauses = segmenter.resize(clauses, at: 0, by: -1) }
        #expect(clauses.map(\.kind) == original.map(\.kind))
        #expect(readings(clauses) == readings(original))
    }

    /// 括弧をまたいでまとめた文節は、前の文節を伸縮して後ろを変換し直しても 1 文節のまま残る
    @Test func keepsAJoinedClauseWholeWhenAnEarlierClauseIsResized() throws {
        var clauses = segmenter.clauses("kyouhanihon(cafe)desu")
        let bracket = try #require(clauses.firstIndex { $0.reading == "（" })
        for _ in 0..<4 { clauses = segmenter.resize(clauses, at: bracket, by: 1) }
        #expect(readings(clauses).contains("（かふぇ）"))
        clauses = segmenter.resize(segmenter.resize(clauses, at: 0, by: 1), at: 0, by: -1)
        #expect(readings(clauses).contains("（かふぇ）"))
    }

    /// 利用者が伸縮で範囲を決めた文節は、前の文節を伸縮して後ろを変換し直しても、その範囲のまま残る。表記は区間の全体を変換したものを切る
    @Test func keepsTheRangeTheUserSetWhenAnEarlierClauseIsResized() throws {
        var clauses = segmenter.clauses("kinouwatasihagooglewotukatta")
        let wo = try #require(clauses.firstIndex { $0.reading == "を" })
        clauses = segmenter.resize(segmenter.resize(clauses, at: wo, by: 1), at: wo, by: 1)
        #expect(Array(readings(clauses).suffix(2)) == ["をつか", "った"])
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        #expect(Array(readings(clauses).suffix(2)) == ["をつか", "った"])
        #expect(clauses.suffix(2).map(\.output).joined() == "を使った")
        // 変換し直した後も、範囲を決めた印は残る
        clauses = segmenter.resize(clauses, at: 0, by: -1)
        #expect(Array(readings(clauses).suffix(2)) == ["をつか", "った"])
    }

    /// 範囲の端を表記の上で切れないときは、その範囲を守らず、範囲を決めなかったときと同じ区切りにする（「をつ」の つ は 使 の中）
    @Test func fallsBackToTheConverterCutsWhenAnEndCannotBeCut() throws {
        let input = "kinouwatasihagooglewotukatta"
        var clauses = segmenter.clauses(input)
        let wo = try #require(clauses.firstIndex { $0.reading == "を" })
        clauses = segmenter.resize(clauses, at: wo, by: 1)
        #expect(clauses[wo].reading == "をつ")
        let unset = segmenter.resize(segmenter.clauses(input), at: 0, by: 1)
        #expect(readings(segmenter.resize(clauses, at: 0, by: 1)) == readings(unset))
    }

    /// 同じ区間の後ろで範囲を決めた文節も、前の文節を区間の中で伸縮して残りを作り直したとき、その範囲のまま残る。
    /// 縮めて余った読みを受け取るすぐ後ろの文節は、範囲を決めていても作り直す
    @Test func keepsTheRangeTheUserSetLaterInTheSameSpan() throws {
        var clauses = segmenter.clauses("kyouhaasitanoyoteiwokimetaikedo")
        try #require(clauses.count >= 3 && clauses.allSatisfy { $0.span == clauses[0].span })
        clauses = segmenter.resize(clauses, at: clauses.count - 1, by: -1)
        let kept = Array(readings(clauses).suffix(2))
        #expect(kept.last == "ど")
        clauses = segmenter.resize(clauses, at: 0, by: -1)
        #expect(Array(readings(clauses).suffix(2)) == kept)
    }

    /// 前の英語の文節を伸縮して後ろの打鍵を日英判定からやり直しても、後ろで範囲を決めた文節は、新しい日本語区間に収まればその範囲のまま残る
    @Test func keepsTheRangeTheUserSetWhenTheSpansAfterAreJudgedAgain() throws {
        var clauses = segmenter.clauses("githubnipushsitakedodameda")
        #expect(clauses[0].kind == .english)
        let sita = try #require(clauses.firstIndex { $0.reading.hasPrefix("したけど") })
        clauses = segmenter.resize(clauses, at: sita, by: -1)
        let kept = Array(readings(clauses).dropFirst(sita))
        #expect(kept.first?.hasSuffix("ど") == false)
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        #expect(Array(readings(clauses).suffix(kept.count)) == kept)
    }

    /// 句読点は前の文節にも取り込める。2 文字以下の読める綴りは日本語になり、1 かなは 1 文節になるので、前の文節は え に決まる
    @Test func resizingTakesPunctuationIntoTheClauseBefore() {
        let original = segmenter.clauses("e,ki")
        #expect(readings(original) == ["え", "、", "き"])
        let clauses = segmenter.resize(original, at: 0, by: 1)
        #expect(clauses[0].reading == "え、")
        #expect(clauses[0].kind == .japanese)
    }

    /// 句読点で終わる文節の後ろは、区切りの選択と同じく句読点の後の文の頭として表示する（文の頭の 1 かなは変換しない）
    @Test func showsTheRestAfterATakenPunctuationLikeAfterThePunctuation() throws {
        let original = segmenter.clauses("e,ki")
        let taken = segmenter.resize(original, at: 0, by: 1)
        #expect(readings(taken) == ["え、", "き"])
        let last = try #require(taken.last)
        #expect(last.output == last.reading)
        let shrunk = segmenter.resize(segmenter.resize(original, at: 1, by: 1), at: 1, by: -1)
        #expect(readings(shrunk) == readings(original))
        #expect(shrunk.last?.output == shrunk.last?.reading)
    }

    /// 記号で終わるまとめた文節の後ろは、前の文節を伸縮して変換し直しても、記号の後の文の頭として表示する
    @Test func keepsTheRestAfterAJoinedClauseAtTheSentenceHeadWhenRedisplayed() throws {
        var clauses = segmenter.clauses("kyouhanihon(cafe)ki")
        let bracket = try #require(clauses.firstIndex { $0.reading == "（" })
        for _ in 0..<4 { clauses = segmenter.resize(clauses, at: bracket, by: 1) }
        #expect(Array(readings(clauses).suffix(2)) == ["（かふぇ）", "き"])
        clauses = segmenter.resize(segmenter.resize(clauses, at: 0, by: 1), at: 0, by: -1)
        let last = try #require(clauses.last)
        #expect(last.reading == "き" && last.output == "き")
    }

    // MARK: 途中の確定

    @Test func committingThroughAClauseKeepsTheRestConverted() throws {
        let clauses = segmenter.resize(segmenter.clauses("kyouhaiitenkidesu"), at: 1, by: -5)
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

    // MARK: 英語の区間の文字種

    /// 英語の区間のかなは、打鍵を前から順にかなにし、読めない文字は打ったまま残す。c の綴りも読み、後ろに綴りが続かない単独の n は ん と読む
    @Test(arguments: [
        ("cafe", "かふぇ", "カフェ"), ("github", "ぎてゅb", "ギテュb"), ("conb", "こんb", "コンb"), ("kotlin.", "こtぃん.", "コtィン."),
    ])
    func turnsAnEnglishSpanIntoKanaAsTyped(input: String, hiragana: String, katakana: String) {
        #expect(segmenter.segment(input).map(\.kind) == [.english])
        #expect(segmenter.convertWhole(input, to: .hiragana) == hiragana)
        #expect(segmenter.convertWhole(input, to: .katakana) == katakana)
        let clauses = segmenter.clauses(input)
        #expect(segmenter.convertClause(clauses, at: 0, to: .hiragana) == hiragana)
        #expect(segmenter.convertClause(clauses, at: 0, to: .katakana) == katakana)
    }

    /// c の綴りはかなにするときだけ読み、日英判定の綴りの表では読まない
    @Test func readsCSpellingsOnlyWhenTurningKeysIntoKana() throws {
        let table = try Shared.table.get()
        #expect(table.reading(of: "cafe") == nil)
        #expect(table.typedKana(of: "cafe") == ("かふぇ", true))
        #expect(table.typedKana(of: "github") == ("ぎてゅb", false))
    }

    /// かなにするときだけ読む綴りの表は綴りの行だけを持ち、@ の指定はその表の名前と行を示してエラーにする
    @Test func rejectsDirectivesInTheTypedKanaTable() {
        let error = #expect(throws: RomajiTable.ParseError.self) { try RomajiTable(contents: "a\tあ", typedKana: "ca\tか\n@sokuon\tc") }
        #expect(error == .directiveNotAllowed(file: "romaji-typed-kana.tsv", 2, "@sokuon\tc"))
    }

    /// 英語の区間の候補は、打ったままの綴りの次に全角の英字を並べる。語を読み切れればかなも並べ、読み切れなければ並べない
    @Test func listsFullwidthLettersAfterTheTypedSpelling() {
        let cafe = segmenter.clauses("cafe")[0].candidates
        #expect(Array(cafe.prefix(2)) == ["cafe", "ｃａｆｅ"])
        #expect(cafe.contains("かふぇ"))
        #expect(cafe.contains("カフェ"))
        #expect(segmenter.clauses("github")[0].candidates == ["github", "ｇｉｔｈｕｂ"])
    }
}

/// 本物の変換器に処理を任せ、表示の変換の末尾に読みに無いかなを足して、読みと合わない表示にする
private final class RewritingConverter: JapaneseConverting {
    private let base: JapaneseConverting = Shared.converter

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading { base.convert(kana: kana, context: context) }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { base.alternatives(kana: kana, context: context) }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay {
        let shown = base.display(kana: kana, context: context, left: left)
        var clauses = shown.clauses
        clauses[clauses.count - 1].text += "ゑ"
        return JapaneseDisplay(text: shown.text + "ゑ", clauses: clauses)
    }

    func endComposition() { base.endComposition() }
    func replaceUserWords(_ words: [UserWord]) { base.replaceUserWords(words) }
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
    fileprivate let recorder = DisplayRecorder()
    let segmenter: Segmenter
    /// 日本語区間・英語区間・日本語区間の順に並ぶ入力
    let input = "kawacwdkyouhaii"

    init() throws {
        segmenter = try Shared.make(recorder)
    }

    /// 前の日本語区間を、同じ前の文字列に続けて変換した表記と英語区間をつないだもの
    private func convertedLeft(leading: Segmenter.Leading = .start) throws -> String {
        try Shared.segmenter.get().liveText("kawa", leading: leading) + "cwd"
    }

    /// 入力欄のカーソルより前の文字列を、最初の区間の左の文脈にし、後ろの区間の左の文脈の前にも置く
    @Test func liveTextPassesTheTextBeforeTheCaretToEverySpan() throws {
        let leading = Segmenter.Leading("奈良")
        let left = try convertedLeft(leading: leading)
        _ = segmenter.liveText(input, leading: leading)
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
        let leading = Segmenter.Leading("奈良")
        let leftAfterLeading = try convertedLeft(leading: leading)
        _ = segmenter.clauses(input, leading: leading)
        #expect(recorder.lefts.suffix(2) == ["奈良", "奈良" + leftAfterLeading])
    }

    @Test func resizingRedisplaysTheLaterSpansWithTheNewLeft() {
        let clauses = segmenter.clauses("kyouhaiicwdde")
        let resized = segmenter.resize(clauses, at: 0, by: 1)
        #expect(readings(resized) == ["きょうはい", "い", "cwd", "で"])
        #expect(recorder.lefts.last == resized.dropLast().map(\.output).joined())
    }

    /// 伸縮した後の表示も、入力欄のカーソルより前の文字列に続けて変換する
    @Test func resizingKeepsTheTextBeforeTheCaretInTheLeft() {
        let leading = Segmenter.Leading("奈良")
        let clauses = segmenter.clauses("kyouhaiicwdde", leading: leading)
        let resized = segmenter.resize(clauses, at: 0, by: 1, leading: leading)
        #expect(readings(resized) == ["きょうはい", "い", "cwd", "で"])
        #expect(recorder.lefts.last == "奈良" + resized.dropLast().map(\.output).joined())
    }

    private func readings(_ clauses: [Clause]) -> [String] {
        clauses.map(\.reading)
    }
}

/// 末尾の単独の n を外した残りは、区間の読みから「ん」を外したものとして表示の変換に渡す。綴りの表から読み直さない（3-5 は 3ー5 にならない）
@Suite struct PendingNReadingTests {
    fileprivate let recorder = DisplayRecorder()
    let segmenter: Segmenter

    init() throws {
        segmenter = try Shared.make(recorder)
    }

    @Test(arguments: [("sounaruton", "そうなると"), ("3-5nin", "3-5に")])
    func passesTheReadingBeforeThePendingN(input: String, kana: String) {
        #expect(segmenter.liveText(input).hasSuffix("n"))
        #expect(recorder.kanas.last == kana)
    }
}

/// 文の頭の 1 かなだけを変換器に渡さず、それ以外の 1 かなは変換器に渡す。変換器がどう書くかによらず、表示の変換を呼んだかで確かめる
@Suite struct SentenceHeadKanaTests {
    fileprivate let recorder = DisplayRecorder()
    let segmenter: Segmenter

    init() throws {
        segmenter = try Shared.make(recorder)
    }

    @Test func doesNotConvertALoneKanaAtTheStart() {
        _ = segmenter.liveText("ki")
        #expect(recorder.lefts.isEmpty)
    }

    /// 後ろが打ったままの単独の n だけでも、その手前の 1 かなは末尾の区間として扱う（kon は こn）
    @Test func doesNotConvertALoneKanaBeforeAPendingN() {
        #expect(segmenter.liveText("kon") == "こn")
        #expect(recorder.lefts.isEmpty)
    }

    /// 組に合わせて半角にした閉じ括弧の後ろは英語の後で、文の頭ではない
    @Test func convertsALoneKanaAfterAHalfWidthClosingBracket() throws {
        _ = segmenter.liveText("github(kore)ki")
        #expect(try #require(recorder.lefts.last).hasSuffix(")"))
    }

    /// 文節を伸ばした後ろだけを区切り直すときも、その最初の区間は入力の最初ではない
    @Test func convertsALoneKanaAfterAResizedClause() throws {
        let resized = segmenter.resize(segmenter.clauses("githubkiku"), at: 0, by: 1)
        #expect(resized.first?.output == "githubki")
        #expect(try #require(recorder.lefts.last).hasSuffix("githubki"))
    }
}
