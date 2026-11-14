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

    /// 数字にはさまれた . , : - は、数の一部として打ったまま残す。ほかの記号は直前の区間に従う
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

    /// 長音は直前の音を伸ばす記号なので、英字・数字・句読点・入力の先頭の後ろの - は、どの日本語区間の候補でも ー と読まない
    @Test(arguments: ["us-west-1nidepuroisita.", "3-", "-", "--", "kore,-"])
    func readsNoDashAsALongVowelAfterANonJapaneseLetter(input: String) {
        let longVowels = segmenter.candidates(input).filter { $0.segment.kind == .japanese && $0.segment.reading.contains("ー") }
        #expect(longVowels.isEmpty, "\(longVowels.map(\.segment.reading))")
    }

    /// かなの後ろの - は、入力の中でも、入力欄の日本語の文字（漢字を含む）に続く入力の先頭でも、ー と読む候補に入る
    @Test(arguments: [("kaki--", "", "かきーー"), ("-", "すご", "ー"), ("-", "人気", "ー"), ("-", "ｽｺﾞ", "ー"), ("-", "山﨑", "ー"), ("-", "𠮷", "ー")])
    func readsADashAfterJapaneseAsALongVowel(input: String, field: String, expected: String) {
        #expect(segmenter.candidates(input, leading: Segmenter.Leading(field)).contains { $0.segment.kind == .japanese && $0.segment.reading == expected })
    }

    /// 入力欄が英字や、かなの区画にある音を持たない記号（・）で終わるときは、入力の先頭の - を ー と読まない
    @Test(arguments: ["A", "A・", "3"])
    func readsNoDashAsALongVowelAfterANonJapaneseField(field: String) {
        #expect(!segmenter.candidates("-", leading: Segmenter.Leading(field)).contains { $0.segment.reading.contains("ー") })
    }

    /// 文節を縮めて分けた後ろの文節も、伸ばした文節も、前の文節の見えている文字がかななら、先頭の - を ー と読む
    @Test func readsADashAfterAResizedClauseAsALongVowel() throws {
        var clauses = segmenter.clauses("ra-men.desu")
        for _ in 0..<8 where clauses[0].reading != "ら" {
            clauses = segmenter.resize(clauses, at: 0, by: -1)
        }
        try #require(clauses[0].reading == "ら", "\(clauses.map(\.reading))")
        #expect(clauses[1].reading.hasPrefix("ー"), "\(clauses.map(\.reading))")
        for _ in 0..<5 {
            clauses = segmenter.resize(clauses, at: 1, by: 1)
            #expect(clauses[1].reading.hasPrefix("ー"), "\(clauses.map(\.reading))")
        }
    }

    /// 前の文節を英字にすると、後ろの文節の頭の - は長音と読めない。その文節を伸ばしても止まらず、日本語の文節に打鍵を流さない。
    /// 句読点か記号をまたいで部分を読めない伸縮は取りやめ、文節を操作の前のまま残す
    @Test func keepsTheClausesWhenAResizedPartCannotBeRead() throws {
        var clauses = segmenter.clauses("ra-men.desu")
        for _ in 0..<8 where clauses[0].reading != "ら" {
            clauses = segmenter.resize(clauses, at: 0, by: -1)
        }
        try #require(clauses[0].reading == "ら", "\(clauses.map(\.reading))")
        clauses = Clause.selecting(text: "ra", at: 0, in: clauses)
        for _ in 0..<6 {
            let before = clauses
            clauses = segmenter.resize(clauses, at: 1, by: 1)
            for clause in clauses where clause.kind == .japanese {
                #expect(!clause.reading.contains { $0.isASCII && $0.isLetter }, "\(clauses.map(\.reading))")
            }
            if clauses == before {
                // 取りやめたのは、伸ばすと句読点をまたぐところ（後ろの文節の次が句読点の文節）
                #expect(clauses[1].reading == "ーめん", "\(clauses.map(\.reading))")
                #expect(clauses.count > 2 && clauses[2].kind == .punctuation, "\(clauses.map(\.reading))")
                return
            }
        }
        Issue.record("句読点をまたぐ伸縮が取りやめにならなかった: \(clauses.map(\.reading))")
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

    /// 記号と句読点の文節は、表示と打ったままの形（2 打鍵の記号の打鍵を除く）の後に、表示の記号を読みとする記号を並べる。
    /// 丸括弧の文節には足さず、ほかの文節にも丸括弧を足さない
    @Test func symbolClausesOfferTheSymbolsOfTheirMark() throws {
        let clauses = segmenter.clauses("[kore]")
        let open = try #require(clauses.first?.candidates)
        let close = try #require(clauses.last?.candidates)
        #expect(open.prefix(2) == ["「", "["])
        #expect(open.contains("【") && !open.contains("（"))
        #expect(close.prefix(2) == ["」", "]"])
        #expect(close.contains("】") && !close.contains("）"))
        #expect(!segmenter.clauses("z[")[0].candidates.contains("z["))
        let arrow = segmenter.clauses("zl")[0].candidates
        #expect(arrow.first == "→" && !arrow.contains("zl"))
        #expect(segmenter.clauses("/")[0].candidates.prefix(2) == ["・", "/"])
        let parens = segmenter.clauses("kore(sore)").filter { $0.output == "（" || $0.output == "）" }.map(\.candidates)
        #expect(parens == [["（", "("], ["）", ")"]])
    }

    /// 日本語の文節は、読みを読みとする記号も候補に並べる
    @Test func japaneseClausesOfferTheSymbolsOfTheirReading() throws {
        let clause = try #require(segmenter.clauses("kakko").first { $0.reading == "かっこ" })
        #expect(clause.candidates.contains("【】"))
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
        #expect(output(".", leading: Segmenter.Leading("Hello ")) == ".")
        #expect(output(".", leading: Segmenter.Leading("今日 ")) == "。")
        #expect(output(".", leading: Segmenter.Leading("Hello\n")) == "。")
        #expect(output(".", leading: Segmenter.Leading("Hello.")) == ".")
        #expect(output(".", leading: Segmenter.Leading("今日。")) == "。")
        #expect(output("~", leading: Segmenter.Leading("今日")) == "〜")
        #expect(output("~", leading: Segmenter.Leading("API")) == "~")
    }

    /// 英語の後に続けて打つ記号（wait... really?! wow!!）は、続けて打っても、変換が届く前の表示でも、
    /// 前まで確定してから打っても、どれも打ったまま残る。直前の記号を文の頭として日本語の記号にしない
    @Test(arguments: [("wait", "..."), ("really", "?!"), ("wow", "!!")])
    func keepsMarksTypedAfterEnglishMarks(word: String, marks: String) {
        #expect(segmenter.liveText(word + marks) == word + marks)
        let provisional = Segmenter.liveDisplay(of: word + marks, converted: [(word, segmenter.liveDisplay(word))], leading: .start, table: segmenter.table)
        #expect(provisional.text == word + marks, "変換が届く前")
        #expect(segmenter.liveText(String(marks.dropFirst()), leading: Segmenter.Leading(word + String(marks.first!))) == String(marks.dropFirst()), "確定してから")
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
            case ">": focus = Clause.focus(focus, movedBy: 1, in: clauses)
            default: focus = Clause.focus(focus, movedBy: -1, in: clauses)
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

    /// 選ぶ文節を移すと、空白だけの文節を飛ばし、それ以外の文節にはすべて止まる
    @Test(arguments: ["kyouha node wo", "kyouha make ", "github ni push sita"])
    func movingFocusSkipsSpaceClauses(input: String) {
        let clauses = segmenter.clauses(input)
        let words = clauses.indices.filter { !clauses[$0].reading.allSatisfy { $0 == " " } }
        #expect(words.count < clauses.count, "\(clauses.map(\.reading))")
        var right = [0]
        for _ in 1..<words.count { right.append(Clause.focus(right.last!, movedBy: 1, in: clauses)) }
        #expect(right == words)
        #expect(Clause.focus(right.last!, movedBy: 1, in: clauses) == 0)
        var left = [Clause.focus(0, movedBy: -1, in: clauses)]
        for _ in 1..<words.count { left.append(Clause.focus(left.last!, movedBy: -1, in: clauses)) }
        #expect(left == words.reversed())
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

    /// 同じ区間の後ろで範囲を決めた文節も、前の文節を区間の中で縮めても伸ばしても、残りを作り直したときにその範囲のまま残る
    @Test(arguments: [-1, 1])
    func keepsTheRangeTheUserSetLaterInTheSameSpan(delta: Int) throws {
        var clauses = segmenter.clauses("kyouhaasitanoyoteiwokimetaikedo")
        try #require(clauses.count >= 3 && clauses.allSatisfy { $0.span == clauses[0].span })
        clauses = segmenter.resize(clauses, at: clauses.count - 1, by: -1)
        let kept = Array(readings(clauses).suffix(2))
        #expect(kept.last == "ど")
        clauses = segmenter.resize(clauses, at: 0, by: delta)
        #expect(Array(readings(clauses).suffix(2)) == kept)
    }

    /// 前の英語の文節を伸縮して後ろの打鍵を日英判定からやり直しても、後ろで範囲を決めた文節は、新しい日本語区間に収まればその範囲のまま残る。
    /// 範囲を決めていない後ろの文節の切り方は変換が決めるので、範囲の直後で切れることだけを確かめる
    @Test func keepsTheRangeTheUserSetWhenTheSpansAfterAreJudgedAgain() throws {
        var clauses = segmenter.clauses("githubnipushsitakedodameda")
        try #require(clauses[0].kind == .english)
        let sita = try #require(clauses.firstIndex { $0.reading.hasPrefix("したけど") })
        clauses = segmenter.resize(clauses, at: sita, by: -1)
        let kept = clauses[sita].reading
        try #require(!kept.hasSuffix("ど"))
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        let index = try #require(clauses.firstIndex { $0.reading == kept && $0.fixedRange })
        #expect(clauses.indices.contains(index + 1) && clauses[index + 1].reading.hasPrefix("ど"))
    }

    /// 後ろの文節で選んだ候補は、前の文節を区間の中で伸縮しても、日英判定をやり直す伸縮をしても残る
    @Test(arguments: [("kyouhaasitanoyoteiwokimetaikedo", -1), ("githubnipushsitakedodameda", 1)])
    func keepsTheChosenCandidateWhenAnEarlierClauseIsResized(input: String, delta: Int) throws {
        var clauses = segmenter.clauses(input)
        let last = clauses.count - 1
        try #require(last >= 2 && clauses[last].candidates.count > 1)
        clauses = Clause.selecting(1, at: last, in: clauses)
        let chosen = clauses[last].output
        clauses = segmenter.resize(clauses, at: 0, by: delta)
        #expect(clauses.last?.output == chosen)
    }

    /// F6〜F10 で文字種を変えた文節も、候補を選んだ文節と同じく、前の文節を伸縮しても残る
    @Test func keepsTheCharacterFormChosenWithAFunctionKey() throws {
        var clauses = segmenter.clauses("kyouhaasitanoyoteiwokimetaikedo")
        let last = clauses.count - 1
        try #require(last >= 2)
        let katakana = try #require(segmenter.convertClause(clauses, at: last, to: .katakana))
        clauses = Clause.selecting(text: katakana, at: last, in: clauses)
        clauses = segmenter.resize(clauses, at: 0, by: -1)
        #expect(clauses.last?.output == katakana)
    }

    /// 英語の文節で選んだ表記（全角の英字）も、前の文節を伸縮して後ろの打鍵を日英判定からやり直したとき、打鍵の範囲が同じ文節になれば残る。
    /// github と cwd は綴りの表で読めないので英語、ni と de は 2 文字以下なので日本語になる
    @Test func keepsTheTextChosenOnAnEnglishClauseWhenTheSpansAfterAreJudgedAgain() throws {
        var clauses = segmenter.clauses("githubnicwdde")
        try #require(readings(clauses) == ["github", "に", "cwd", "で"])
        clauses = Clause.selecting(text: "ｃｗｄ", at: 2, in: clauses)
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        let cwd = try #require(clauses.first { $0.reading == "cwd" })
        #expect(cwd.output == "ｃｗｄ")
    }

    /// 先頭の候補に選び直した文節は、何も選ばなかった文節と同じく、前の文節を伸縮すると作り直す
    @Test func selectingTheFirstCandidateAgainLetsTheClauseBeRebuilt() throws {
        let original = segmenter.clauses("githubnicwdde")
        try #require(readings(original) == ["github", "に", "cwd", "で"])
        var clauses = Clause.selecting(text: "ｃｗｄ", at: 2, in: original)
        clauses = Clause.selecting(0, at: 2, in: clauses)
        let resized = segmenter.resize(clauses, at: 0, by: 1)
        #expect(resized.map(\.output) == segmenter.resize(original, at: 0, by: 1).map(\.output))
    }

    /// 丸括弧の形を選び直すと組の括弧も同じ形になり、前の文節を伸縮して後ろを日英判定からやり直しても、両方その形のまま残る。
    /// ( は直前が日本語なら （ になり、候補で打ったままの ( を選べる。github は綴りの表で読めないので英語、ni は 2 文字以下なので日本語になり、
    /// github を伸ばすと に を取り込み、後ろの toka(cafe)desu を日英判定からやり直す
    @Test func keepsBothBracketsOfAChosenFormWhenAnEarlierClauseIsResized() throws {
        var clauses = segmenter.clauses("githubnitoka(cafe)desu")
        let open = try #require(clauses.firstIndex { $0.output == "（" })
        let close = try #require(clauses.firstIndex { $0.output == "）" })
        try #require(clauses[0].reading == "github" && clauses[open - 1].kind == .japanese)
        clauses = Clause.selecting(text: "(", at: open, in: clauses)
        try #require(clauses[close].output == ")")
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        try #require(clauses[0].reading == "githubni")
        let text = clauses.map(\.output).joined()
        #expect(text.contains("(") && text.contains(")"))
        #expect(!text.contains("（") && !text.contains("）"))
    }

    /// 後ろにある、利用者が伸縮で作った区間は、前の文節を伸縮して後ろを日英判定からやり直しても、日英も打鍵の範囲もそのまま残る。
    /// その区間から後ろの文節も、区切りを変えずに残る。github は綴りの表で読めないので英語、e と ni は 2 文字以下なので日本語になる。
    /// githubnipushsita は先頭を伸ばすと に まで取り込むのでやり直す打鍵が無く、e,nipushsita は 、 だけを取り込むので に をやり直す
    @Test(arguments: ["githubnipushsita", "e,nipushsita"])
    func keepsALaterSpanTheUserMadeWhenTheSpansAfterAreJudgedAgain(input: String) throws {
        var clauses = segmenter.clauses(input)
        let push = try #require(clauses.firstIndex { $0.reading == "push" })
        clauses = segmenter.resize(clauses, at: push, by: -1)
        let made = try #require(clauses.first { $0.reading == "pus" })
        #expect(made.kind == .english && made.span.resized)
        let after = spansFrom(made.span.source, in: clauses)
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        #expect(clauses.contains { $0.reading == "pus" && $0.kind == .english && $0.span.resized })
        #expect(spansFrom(made.span.source, in: clauses) == after)
    }

    /// 打鍵 source の区間から後ろの区間の、打鍵・種類・伸縮で作った区間か。区間の中の文節の切り方は変換が決めるので含めない
    private func spansFrom(_ source: String, in clauses: [Clause]) -> [String] {
        var shapes: [String] = []
        var last: ClauseSpan?
        for clause in clauses where clause.span != last {
            last = clause.span
            if shapes.isEmpty, clause.span.source != source { continue }
            shapes.append("\(clause.span.source) \(clause.kind) \(clause.span.resized)")
        }
        return shapes
    }

    /// 作った区間の手前で開き丸括弧の形が変わったら、その区間を残さず後ろを日英判定からやり直すので、閉じ丸括弧は開き丸括弧と同じ形になる。
    /// ( は直前が日本語の に なら （、先頭を伸ばして英語の githubni に取り込ませると打ったままの ( になる
    @Test func rejudgesAMadeSpanWhenTheOpenBracketBeforeItChangesForm() throws {
        var clauses = segmenter.clauses("githubni(pushsita)")
        let push = try #require(clauses.firstIndex { $0.reading == "push" })
        clauses = segmenter.resize(clauses, at: push, by: -1)
        try #require(clauses.contains { $0.reading == "pus" && $0.span.resized } && clauses.contains { $0.output == "（" })
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        try #require(clauses[0].reading == "githubni")
        let text = clauses.map(\.output).joined()
        #expect(text.filter { $0 == "(" }.count == text.filter { $0 == ")" }.count)
        #expect(text.filter { $0 == "（" }.count == text.filter { $0 == "）" }.count)
    }

    /// 作った区間は、伸ばした文節に取り込まれたときと、縮めて手放した打鍵のすぐ後ろにあるときは残さず、日英判定をやり直す。
    /// e,pushsita の push を pus に縮め、残った h を hsi に伸ばしてから、pus を伸縮する
    @Test(arguments: [1, -1])
    func rejudgesAMadeSpanTakenInOrRightAfterTheReleasedKeys(delta: Int) throws {
        var clauses = segmenter.clauses("e,pushsita")
        let push = try #require(clauses.firstIndex { $0.reading == "push" })
        clauses = segmenter.resize(clauses, at: push, by: -1)
        clauses = segmenter.resize(clauses, at: push + 1, by: 1)
        try #require(readings(clauses).contains("hsi") && clauses[push].reading == "pus")
        clauses = segmenter.resize(clauses, at: push, by: delta)
        #expect(!clauses.contains { $0.reading == "hsi" })
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

    /// 確定する文節の直後の空白は一緒に確定し、残りは空白で始まらない。空白だけが残るなら残りは空
    @Test func committingThroughAClauseTakesTheSpacesAfterIt() throws {
        let clauses = segmenter.clauses("kyouha node wo")
        let first = try #require(segmenter.commit(clauses, through: 0))
        #expect(first.text == clauses[0].output + " ")
        #expect(first.keys == "node wo")
        #expect(first.rest.first?.isSpace == false)
        let trailing = segmenter.clauses("kyouha ")
        let last = try #require(segmenter.commit(trailing, through: 0))
        #expect(last.rest.isEmpty)
        #expect(last.keys == "")
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

    /// 空白の直後の句読点と開き丸括弧は、空白を飛ばした前の区間が日本語なら日本語の記号、英語なら打ったままにする。
    /// 変換が届く前の表示も同じ形にし、空白の前まで確定してから打っても同じ形にする
    @Test(arguments: [("kyou ", ",", "、"), ("make ", ",", ","), ("kyouha ", "(tesuto", "（"), ("github ", "(tesuto", "(")])
    func decidesPunctuationAfterASpaceByTheTextBeforeIt(before: String, typed: String, mark: String) {
        let input = before + typed
        #expect(segmenter.liveText(input).contains(mark), "\(input)")
        let provisional = Segmenter.liveDisplay(of: input, converted: [(before, segmenter.liveDisplay(before))], leading: .start, table: segmenter.table)
        #expect(provisional.text.contains(mark), "変換が届く前: \(input)")
        let committed = segmenter.liveText(typed, leading: Segmenter.Leading(segmenter.liveText(before)))
        #expect(committed.contains(mark), "確定してから: \(input)")
    }

    /// 空白の直後の句読点も入力を切るので、その後ろの語は句読点を含めずに読む。英語の語でない読める綴り（tesu）は日本語になる
    @Test func readsTheWordAfterPunctuationAfterASpaceOnItsOwn() {
        #expect(!segmenter.liveText("kyouha (tesu").contains("tesu"))
    }

    /// 空白は入力を切るので、空白までの区切りは、空白を打った時点の区切りから後ろに打った分で変わらない
    @Test(arguments: ["kyouha node wo sakujo suru", "sake wo nomu", "github ni push sita", "kore ha 3 ko desu"])
    func keepsTheSegmentsBeforeASpace(input: String) {
        let whole = segmenter.segment(input)
        for (index, char) in input.enumerated() where char == " " {
            let typed = segmenter.segment(String(input.prefix(index + 1)))
            #expect(Array(whole.prefix(typed.count)) == typed, "\(input.prefix(index + 1))")
        }
    }

    /// 空白の後の Space は、末尾の空白の前の 1 語を、今の区切りと反対の言語の 1 文節にする。どちらの言語に読まれるかは点で決まるので、
    /// 今の区切りの種類を読んでから、その反対になることを確かめる。打っている途中に見えていた語の表示を 2 番目の候補に置き、
    /// 語より前は語の手前までを入力として区切る
    @Test(arguments: ["kyouha make ", "kyou ", "kono hide  ", "watasi ha nomu "])
    func flipsTheLastWordBeforeTheSpaceToTheOtherLanguage(input: String) throws {
        let word = input.trimmingCharacters(in: .whitespaces).split(separator: " ").last.map(String.init)!
        let wordStart = input.reversed().drop { $0 == " " }.count - word.count
        var position = 0
        let wasEnglish = segmenter.segment(input).allSatisfy { segment in
            defer { position += segment.source.count }
            return position + segment.source.count <= wordStart || segment.kind == .english
        }
        let (clauses, focus) = try #require(segmenter.clausesFlippingLastWord(input))
        let flipped = clauses[focus]
        #expect(flipped.span.source == word)
        #expect(flipped.kind == (wasEnglish ? .japanese : .english))
        if !wasEnglish { #expect(flipped.output == word) }
        let before = String(input.prefix(wordStart))
        // 空白より前の表示は後ろの打鍵で変わらないので、見えていた語の表示は、全体の表示から語の前の表示と末尾の空白を除いたもの
        let shown = segmenter.liveText(input).dropFirst(segmenter.liveText(before).count).trimmingCharacters(in: .whitespaces)
        #expect(flipped.candidates[1] == shown)
        #expect(clauses[..<focus].map(\.output).joined() == segmenter.clauses(before).map(\.output).joined())
        #expect(clauses[(focus + 1)...].map(\.output).joined() == String(repeating: " ", count: input.count - wordStart - word.count))
    }

    /// 空白で終わらない、空白しか無い、語が句読点か記号を含む、数字だけ、英語の語が日本語に読み切れないときは、反対の言語にしない（Space は空白を足す）
    @Test(arguments: ["make", " ", "kyou, ", "kore[ ", "kore ha 3 ", "github "])
    func keepsTheWordWhenItCannotFlip(input: String) {
        #expect(segmenter.clausesFlippingLastWord(input) == nil)
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

/// 本物の変換器に処理を任せ、決めた読みの表示の変換だけを、決めた文節と表記にする
private final class FixedDisplayConverter: JapaneseConverting {
    private let base: JapaneseConverting = Shared.converter
    private let fixed: [String: [JapaneseClause]]

    init(_ fixed: [String: [JapaneseClause]]) {
        self.fixed = fixed
    }

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading { base.convert(kana: kana, context: context) }

    func alternatives(kana: String, context: JapaneseContext) -> [String] { base.alternatives(kana: kana, context: context) }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay {
        guard let clauses = fixed[kana] else { return base.display(kana: kana, context: context, left: left) }
        return JapaneseDisplay(text: clauses.map(\.text).joined(), clauses: clauses)
    }

    func endComposition() { base.endComposition() }
    func replaceUserWords(_ words: [UserWord]) { base.replaceUserWords(words) }
}

/// 利用者が伸縮で範囲を決めた文節を、後ろを変換し直すときに守るかは、範囲の端を表示の変換の表記の上で切れるかで決まる。
/// 表記は変換器が決めるので、をつかった の表示を を｜使った に決めて確かめる。google は綴りの表で読めないので英語の区間になり、
/// 前後の日本語区間を分ける
@Suite struct FixedRangeCutTests {
    let segmenter: Segmenter
    let input = "kinouwatasihagooglewotukatta"

    init() throws {
        segmenter = try Shared.make(FixedDisplayConverter([
            "をつかった": [JapaneseClause(reading: "を", text: "を"), JapaneseClause(reading: "つかった", text: "使った")],
        ]))
    }

    private func readings(_ clauses: [Clause]) -> [String] {
        clauses.map(\.reading)
    }

    /// 範囲の端（をつか の後ろ）を 使った の後ろで切れるので、前の文節を伸縮して後ろを変換し直しても、その範囲のまま残る。
    /// 表記は区間の全体を変換したものを切るので、つなぐと範囲を決めずに同じ伸縮をしたときと同じ文字列になる
    @Test func keepsTheRangeTheUserSetWhenAnEarlierClauseIsResized() throws {
        var clauses = segmenter.clauses(input)
        #expect(Array(readings(clauses).suffix(2)) == ["を", "つかった"])
        let wo = clauses.count - 2
        clauses = segmenter.resize(segmenter.resize(clauses, at: wo, by: 1), at: wo, by: 1)
        #expect(Array(readings(clauses).suffix(2)) == ["をつか", "った"])
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        #expect(Array(readings(clauses).suffix(2)) == ["をつか", "った"])
        let unset = segmenter.resize(segmenter.clauses(input), at: 0, by: 1)
        #expect(clauses.map(\.output).joined() == unset.map(\.output).joined())
        // 変換し直した後も、範囲を決めた印は残る
        clauses = segmenter.resize(clauses, at: 0, by: -1)
        #expect(Array(readings(clauses).suffix(2)) == ["をつか", "った"])
    }

    /// 表記を選んだ文節は、範囲の端が 使 の中に当たって切れなくても、前後の読みを分けて変換し、その範囲と表記のまま残す
    @Test func keepsAChosenClauseWhoseEndCannotBeCut() {
        var clauses = segmenter.clauses(input)
        let wo = clauses.count - 2
        clauses = segmenter.resize(clauses, at: wo, by: 1)
        clauses = Clause.selecting(text: "をツ", at: wo, in: clauses)
        let resized = segmenter.resize(clauses, at: 0, by: 1)
        #expect(Array(readings(resized).suffix(2)) == ["をつ", "かった"])
        #expect(resized[resized.count - 2].output == "をツ")
    }

    /// 範囲の端（をつ の後ろ）が 使 の中に当たって切れないときは、その範囲を守らず、表示の変換の区切りにする
    @Test func fallsBackToTheConverterCutsWhenAnEndCannotBeCut() {
        var clauses = segmenter.clauses(input)
        let wo = clauses.count - 2
        clauses = segmenter.resize(clauses, at: wo, by: 1)
        #expect(clauses[wo].reading == "をつ")
        let resized = segmenter.resize(clauses, at: 0, by: 1)
        #expect(Array(readings(resized).suffix(2)) == ["を", "つかった"])
        #expect(readings(resized) == readings(segmenter.resize(segmenter.clauses(input), at: 0, by: 1)))
    }

    /// 範囲を守っても、範囲の外の変換の区切りは、漢字と漢字の間（東京｜大学）でもそのまま残る。
    /// e は 2 文字以下の読める綴りなので日本語になり、`,` の後ろの toukyoudaigakuheitta は 1 つの日本語区間になる
    @Test func keepsTheConverterCutsOutsideTheRange() throws {
        let segmenter = try Shared.make(FixedDisplayConverter([
            "とうきょうだいがくへいった": [
                JapaneseClause(reading: "とうきょう", text: "東京"),
                JapaneseClause(reading: "だいがくへ", text: "大学へ"),
                JapaneseClause(reading: "いった", text: "行った"),
            ],
        ]))
        var clauses = segmenter.clauses("e,toukyoudaigakuheitta")
        try #require(readings(clauses) == ["え", "、", "とうきょう", "だいがくへ", "いった"])
        let last = clauses.count - 1
        clauses = segmenter.resize(segmenter.resize(clauses, at: last, by: -1), at: last, by: 1)
        try #require(clauses[last].reading == "いった" && clauses[last].fixedRange)
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        #expect(readings(clauses) == ["え、", "とうきょう", "だいがくへ", "いった"])
        #expect(clauses.last?.fixedRange == true)
    }
}

/// 打っている途中の表示が、変換して見せた区間で読みと合わないかを返す
@Suite struct LiveDisplayTests {
    @Test func flagsAConvertedSpanThatDoesNotFollowTheReading() throws {
        let segmenter = try Shared.make(RewritingConverter())
        #expect(segmenter.liveDisplay("kawacwdkyouhaii").differsFromInput)
    }
}

/// 文の頭の 1 かなを変換せずに見せるのは、それが入力の最後の区間のときだけ。後ろに区間が続くなら変換に渡す
@Suite struct LastKanaDisplayTests {
    fileprivate let recorder = DisplayRecorder()
    let segmenter: Segmenter

    init() throws {
        segmenter = try Shared.make(recorder)
    }

    @Test(arguments: [(true, [String]()), (false, ["き"])])
    func convertsTheLastKanaOnlyWhenTheInputContinues(endsInput: Bool, converted: [String]) {
        _ = segmenter.displays(
            of: [.japanese(kana: "き", context: .start, startsSentence: false)], left: "", startsAtHead: true, endsInput: endsInput, endsWithPendingN: false
        ) { _, display, _ in (result: (), shown: display?.text ?? "") }
        #expect(recorder.kanas == converted)
    }

    /// 前の文節を伸縮して後ろを日英判定からやり直すとき、作った区間の手前の最後が文の頭の 1 かなでも、入力の終わりではないので変換に渡す。
    /// e,kiwapushsita の きわ を き と わ に分け、わ を p まで伸ばして読めない英字を含む作った区間 wap にしてから、e を `,` まで伸ばす
    @Test func convertsTheLastKanaBeforeAKeptSpan() throws {
        var clauses = segmenter.clauses("e,kiwapushsita")
        try #require(clauses.prefix(3).map(\.reading) == ["え", "、", "きわ"])
        clauses = segmenter.resize(clauses, at: 2, by: -1)
        clauses = segmenter.resize(clauses, at: 3, by: 1)
        try #require(clauses[2].reading == "き" && clauses.contains { $0.reading == "wap" && $0.span.resized })
        let before = recorder.kanas.count
        clauses = segmenter.resize(clauses, at: 0, by: 1)
        try #require(clauses[0].reading == "え、" && clauses.contains { $0.reading == "wap" && $0.span.resized })
        #expect(recorder.kanas.dropFirst(before).contains("き"))
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

    /// 前の文節を伸縮して後ろの区間を変換し直すとき、表記を選んだ文節の後ろの区間は、選んだ表記を左の文脈にして変換する
    @Test func resizingPassesTheChosenTextToTheLaterSpans() throws {
        var clauses = segmenter.clauses("kawacwdkyouhacwdde")
        try #require(clauses.first?.reading == "かわ" && clauses.last?.reading == "で")
        let chosen = try #require(clauses.lastIndex { $0.kind == .japanese && $0.reading != "で" })
        let text = try #require(segmenter.convertClause(clauses, at: chosen, to: .katakana))
        clauses = Clause.selecting(text: text, at: chosen, in: clauses)
        _ = segmenter.resize(clauses, at: 0, by: -1)
        #expect(recorder.kanas.last == "で")
        #expect(recorder.lefts.last?.hasSuffix(text + "cwd") == true)
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

/// Backspace で残した表示（keepDisplay）を、打っている途中の表示と文節の両方が使う
@Suite struct KeptDisplayTests {
    /// 覚えさせると状態が変わるので、共有の segmenter を使わない
    let segmenter: Segmenter

    init() throws {
        segmenter = try Shared.make(LatticeConverter(dictionary: TestDictionary.shared))
    }

    @Test(arguments: [
        ("toukyounii", "東京に行"),
        ("bassisi", "抜歯し"),
        ("toxtu", "とっ"),
        ("makewosu", "makeをす"),
        ("kyo", "きょ"),
    ])
    func clausesShowTheKeptText(keys: String, text: String) throws {
        let kept = try #require(segmenter.keepDisplay(text, for: keys, leading: .start))
        #expect(kept.text == text)
        #expect(segmenter.liveDisplay(keys).text == text)
        #expect(segmenter.clauses(keys).map(\.output).joined() == text)
    }

    /// 区間に割り当てられない表示は覚えない
    @Test func refusesTextThatDoesNotFollowTheKeys() {
        let before = segmenter.liveDisplay("toukyounii").text
        #expect(segmenter.keepDisplay("大阪に", for: "toukyounii", leading: .start) == nil)
        #expect(segmenter.liveDisplay("toukyounii").text == before)
    }

    /// 未確定の文字列が終わると、覚えた表示は捨てる
    @Test func forgetsAtTheEndOfTheComposition() throws {
        let original = segmenter.liveDisplay("toukyounii").text
        _ = try #require(segmenter.keepDisplay("東京に行", for: "toukyounii", leading: .start))
        segmenter.endComposition()
        #expect(segmenter.liveDisplay("toukyounii").text == original)
    }
}

/// 区切りの結果から作った表示は、最後の区間が英語かを持つ（Backspace で消す単位を決める）
@Suite struct LiveDisplayLastSpanTests {
    @Test(arguments: [("github", true), ("toukyou", false), ("toukyougithub", true), ("githubni", false)])
    func knowsWhetherTheLastSpanIsEnglish(keys: String, english: Bool) throws {
        #expect(try Shared.segmenter.get().liveDisplay(keys).endsInEnglish == english)
    }
}
