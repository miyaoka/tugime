import Foundation
import Testing
@testable import TugimeCore

@Suite struct UserDictionaryTests {
    /// 空行と # の行は読まず、同じ打鍵に別の表記を置ける。CRLF の改行でも同じに読む
    @Test func readsKeysAndWordPerLine() throws {
        let dictionary = UserDictionary(contents: "# 麻雀\r\ni-sou\t一索\r\n\r\nmannzu\t萬子\r\nmannzu\tマンズ\r\ngithub\tGitHub\r\n")
        #expect(dictionary.entries.map { [$0.keys, $0.word] } == [["i-sou", "一索"], ["mannzu", "萬子"], ["mannzu", "マンズ"], ["github", "GitHub"]])
    }

    /// 種類を書かなければ、表記が ASCII だけなら英語、それ以外は日本語にする。書けばそれに従う
    @Test func decidesTheKindFromTheWordUnlessWritten() throws {
        let dictionary = UserDictionary(contents: "mannzu\t萬子\ngithub\tGitHub\nnode\tNode.js™\ncafe\tCafé\nsake\tSAKE\tja\nkara\t唐\ten\n")
        #expect(dictionary.entries.map(\.kind) == [.japanese, .english, .japanese, .japanese, .japanese, .english])
    }

    /// 読めない行は 1 始まりの行番号の誤りとして残し、飛ばしたほかの行を使う
    @Test(arguments: [
        ("i-sou\t一索\nryannsou", UserDictionary.ParseError.malformedLine(2, "ryannsou")),
        ("i-sou\t一索\t牌", .unknownKind(1, "牌")),
        ("i-sou\t一索\tja\t牌", .malformedLine(1, "i-sou\t一索\tja\t牌")),
        ("\t一索", .malformedLine(1, "\t一索")),
        ("いーそう\t一索", .invalidKeys(1, "いーそう")),
        ("i sou\t一索", .invalidKeys(1, "i sou")),
        ("zhang\t張", .unreachableKeys(1, "zhang")),
        (",net\t.NET", .unreachableKeys(1, ",net")),
        ("i-sou\t一索\n\ni-sou\t一索", .duplicateEntry(3, "i-sou\t一索")),
    ])
    func skipsLinesItCannotRead(contents: String, error: UserDictionary.ParseError) {
        let dictionary = UserDictionary(contents: contents + "\nmannzu\t萬子")
        #expect(dictionary.skipped == [error])
        #expect(dictionary.entries.last == UserDictionary.Entry(keys: "mannzu", word: "萬子", declaredKind: nil))
    }
}

/// 本物の変換器に利用者の語を入れる
@Suite struct UserWordConversionTests {
    let converter = LatticeConverter(dictionary: TestDictionary.shared)

    /// 入力全体が利用者の語 1 つでも、その語に変換し、候補の窓にも並べる
    @Test func convertsAndListsTheUserWord() throws {
        converter.replaceUserWords([UserWord(reading: "いーそう", word: "一索牌")])
        let reading = converter.convert(kana: "いーそう", context: .start)
        #expect(reading.text == "一索牌")
        #expect(reading.clauses.map { $0.userWords.map(\.spellings) } == [[["一索牌"]]])
        #expect(converter.alternatives(kana: "いーそう", context: .start).contains("一索牌"))
    }

    /// 英語の後の文脈でも、利用者の語はその語の文節に付く
    @Test func marksTheUserWordAfterAWord() throws {
        converter.replaceUserWords([UserWord(reading: "いーそう", word: "一索牌")])
        let reading = converter.convert(kana: "いーそうをきる", context: .afterWord)
        #expect(reading.clauses.flatMap(\.userWords).map(\.spellings) == [["一索牌"]])
        #expect(reading.text.hasPrefix("一索牌"))
    }

    /// 使った語には、同じ読みに登録した表記をすべて添える。表示はそのどれかを含めばよい
    @Test func listsEverySpellingOfTheReading() throws {
        converter.replaceUserWords([UserWord(reading: "まんず", word: "萬子"), UserWord(reading: "まんず", word: "マンズ")])
        let reading = converter.convert(kana: "まんず", context: .start)
        #expect(reading.clauses.flatMap(\.userWords).map(\.spellings) == [["萬子", "マンズ"]])
        let listed = converter.alternatives(kana: "まんず", context: .start)
        #expect(listed.contains("萬子") && listed.contains("マンズ"))
    }

    /// 表記に読みに無いかなを含む語を使った表示は、読みと合う
    @Test func matchesTheReadingWithAUserWordThatAddsKana() throws {
        converter.replaceUserWords([UserWord(reading: "よろしく", word: "よろしくお願いします")])
        let shown = converter.display(kana: "よろしく", context: .start, left: "")
        #expect(shown.text == "よろしくお願いします")
        #expect(shown.matchesReading)
    }

    /// ゕ ゖ を含む読みの語も引ける
    @Test func findsAReadingWithSmallKa() throws {
        converter.replaceUserWords([UserWord(reading: "いっゕげつ", word: "壱ヶ月")])
        #expect(converter.alternatives(kana: "いっゕげつ", context: .start).contains("壱ヶ月"))
    }

    /// 5000 語でも入れた語を引ける
    @Test func findsWordsInALargeDictionary() throws {
        let digits = Array("あいうえおかきくけこ")
        let words = (0..<5000).map { n in UserWord(reading: "ゆーざー" + String(String(n).map { digits[$0.wholeNumberValue!] }), word: "語\(n)") }
        converter.replaceUserWords(words + [UserWord(reading: "いーそう", word: "一索牌")])
        #expect(converter.convert(kana: "いーそう", context: .start).text == "一索牌")
        #expect(converter.alternatives(kana: "ゆーざーいおう", context: .start).contains("語142"))
    }

    /// 登録数でコストが増え、読みを辞書の語（この｜へん）で覆う道が勝っても、その読みは利用者の語にする。
    /// 表記が読みと同じ語も、使った語として文節に付く
    @Test(arguments: ["此の邊", "このへん"])
    func takesTheUserWordOverDictionaryWordsCoveringItsReading(word: String) throws {
        let others = ["まんず", "いーそう", "りゃんそう"].map { UserWord(reading: $0, word: $0) }
        converter.replaceUserWords([UserWord(reading: "このへん", word: word)] + others)
        let reading = converter.convert(kana: "このへんで", context: .start)
        #expect(reading.text == word + "で")
        #expect(reading.clauses.flatMap(\.userWords).map(\.spellings) == [[word]])
    }

    /// 文節の途中で助詞や活用の並びが登録した読みと重なっても、利用者の語にしない。英語の語の後で助詞から始まる区間も同じ
    @Test(arguments: [
        ("にし", "西", "かれにしては", JapaneseContext.start), ("から", "殻", "なにから", .start), ("かな", "カナ", "そうかな", .start),
        ("にし", "西", "にしては", .afterWord),
    ])
    func keepsFunctionWordsThatShareTheReading(reading: String, word: String, kana: String, context: JapaneseContext) throws {
        converter.replaceUserWords([UserWord(reading: reading, word: word)])
        let converted = converter.convert(kana: kana, context: context)
        #expect(!converted.text.contains(word))
        #expect(converted.clauses.flatMap(\.userWords).isEmpty)
    }

    /// 利用者の語にした範囲の前後でも、文節の区切りは置き換える前と同じにする（たべてみる を たべて｜みる に割らない）
    @Test func keepsClausesAroundTheUserWord() throws {
        let before = converter.convert(kana: "たべてみる", context: .start).clauses.map(\.clause.reading)
        converter.replaceUserWords([UserWord(reading: "たべて", word: "食べて")])
        let reading = converter.convert(kana: "たべてみる", context: .start)
        #expect(reading.clauses.map(\.clause.reading) == before)
        #expect(reading.clauses.flatMap(\.userWords).map(\.spellings) == [["食べて"]])
    }

    /// 置き換えると前の語は消える。採点の覚えが前の辞書の計算を使い回さない
    @Test func replacingDropsThePreviousWords() throws {
        converter.replaceUserWords([UserWord(reading: "いーそう", word: "一索牌")])
        #expect(converter.convert(kana: "いーそう", context: .start).text == "一索牌")
        converter.replaceUserWords([])
        let reading = converter.convert(kana: "いーそう", context: .start)
        #expect(reading.text != "一索牌")
        #expect(reading.clauses.flatMap(\.userWords).isEmpty)
    }
}

/// 打鍵で登録した辞書を、区切りに入れる
@Suite struct UserDictionarySegmenterTests {
    let segmenter: Segmenter

    init() throws {
        segmenter = try Shared.make(LatticeConverter(dictionary: TestDictionary.shared))
        segmenter.replaceUserDictionary(UserDictionary(contents: "mannzu\t萬子\ngithub\tGitHub\nnode\tNode.js\ntugime\ttugime\n2fa\t2FA\nkanon\tKanon\nsake\t鮭\tja\ncafe\tCafé\ncwd\tすご\tja\npwd\tPWD\tja\nresume\trésumé\ten\nqqx\t第2\tja\nyahoo\tYahoo!\ten\njpy\t円\ten\njpy.dev\tCurrency API\ten\nvue\tVue\ten\n404\tNot Found\ten\n110\t警察\ten\npwd.x\tPWDX\tja\nai\tAI\tja"))
    }

    /// 登録した語の後ろの句読点は、区間の種類（日本語か英語か）ではなく、語の見えている表記の最後の字で、確定済みの文字列の後と同じく形を決める。
    /// 日本語の文字の後は日本語の記号、ラテン文字（é を含む）や記号の後は打ったまま。数で終われば数の前の文字で決める。続けて打っても、語まで確定してから打っても同じ形になる。
    /// 変換が届く前の表示の句読点も同じ形になる。ただし登録した表記が打鍵と違う綴りで始まり、日本語の側の字で終わる語（qqx → 第2、jpy → 円）は、
    /// 届く前は打鍵の全体を打ったまま読み直し（qqx,）、句読点の前の字が変わるので、届く前を比べない
    @Test(arguments: [
        ("pwd", "PWD", ",", true), ("resume", "résumé", ",", true), ("cafe", "Café", ",", true),
        ("qqx", "第2", "、", false), ("yahoo", "Yahoo!", ",", true), ("jpy", "円", "、", false),
    ])
    func punctuatesAfterAUserWordByItsShownLetter(keys: String, shown: String, mark: String, comparesProvisional: Bool) {
        #expect(segmenter.liveText(keys + ",") == shown + mark)
        if comparesProvisional {
            let beforeConversion = Segmenter.liveDisplay(of: keys + ",", converted: [(keys, segmenter.liveDisplay(keys))], leading: .start, table: segmenter.table)
            #expect(beforeConversion.text.last == mark.last, "変換が届く前")
        }
        #expect(segmenter.liveText(",", leading: Segmenter.Leading(shown)) == mark, "確定してから")
    }

    /// 登録した語の後ろの句読点で入力を切る前に、句読点をまたいで登録したもっと長い打鍵（jpy.dev、pwd.x）がそのまま打たれていれば、その語として読む
    @Test(arguments: [("jpy.dev", "Currency API"), ("jpy.dev,", "Currency API,"), ("pwd.x", "PWDX"), ("jpy.", "円。"), ("pwd.", "PWD.")])
    func readsARegisteredKeyAcrossPunctuation(keys: String, shown: String) {
        #expect(segmenter.liveText(keys) == shown)
    }

    /// かなに読める打鍵を日本語として登録した語（ai → AI）は日本語区間の中で表記が決まる。その後ろの句読点も、見えている表記の最後の字（空白は飛ばす）で決め、
    /// 語まで確定してから打った場合と同じ形にする。開き丸括弧を打ったままにしたら、組の閉じ丸括弧も同じ形にする。日本語の表記の後ろは日本語の記号のまま。
    /// 打っている途中の表示と文節の両方で、句読点の文字だけを比べる
    @Test(arguments: [
        ("ai,", ","), ("korehaai.", "."), ("ai(sore)", "()"), ("ai ,", ","), ("ai (sore)", "()"), ("kore(ai)", "（）"), ("kyouha,", "、"),
    ])
    func punctuatesAfterAJapaneseUserWordByItsShownForm(keys: String, marks: String) {
        let isMark = { (c: Character) in Segmenter.punctuation[c] != nil || Segmenter.punctuation.values.contains(String(c)) }
        #expect(String(segmenter.liveText(keys).filter(isMark)) == marks)
        #expect(String(segmenter.clauses(keys).map(\.output).joined().filter(isMark)) == marks, "文節")
    }

    /// 語の文節で候補を選び替えたら、後ろの句読点（空白は飛ばす）も選んだ表記の最後の字で決め直す。句読点の形を選んだ文節は替えない
    @Test(arguments: ["ai,", "ai ,"])
    func punctuatesAfterTheCandidateChosenForTheWordBefore(keys: String) throws {
        let clauses = segmenter.clauses(keys)
        let mark = try #require(clauses.indices.last)
        let kana = try #require(clauses[0].candidates.firstIndex(of: "あい"))
        let chosen = Clause.selecting(kana, at: 0, in: clauses)
        #expect(chosen[mark].output == "、")
        #expect(Clause.selecting(0, at: 0, in: chosen)[mark].output == ",", "先頭の候補に戻す")
        let wide = try #require(clauses[mark].candidates.firstIndex(of: "，"))
        #expect(Clause.selecting(kana, at: 0, in: Clause.selecting(wide, at: mark, in: clauses))[mark].output == "，", "句読点の形を選んだ文節")
    }

    /// Backspace で残す表示は、句読点を決め直した表示でも、区間に割り当てて残せる
    @Test func keepsADisplayWithARedecidedMark() throws {
        let kept = try #require(segmenter.keepDisplay("AI,これ。東京に行", for: "ai,kore.toukyounii", leading: .start))
        #expect(kept.text == "AI,これ。東京に行")
    }

    /// 登録した語の後ろの数の後ろの句読点は、数の前の語の表記で決める（Vue3. は e の側）。数字だけの打鍵で登録した語（404 → Not Found）は数ではなく語なので、その表記で決める
    @Test(arguments: [("vue3.", "Vue3."), ("kyou 404,", "今日 Not Found,"), ("API 110,", "API 警察、")])
    func punctuatesAfterANumberByTheUserWordBeforeIt(keys: String, shown: String) {
        #expect(segmenter.liveText(keys) == shown)
    }

    /// 登録した語の文節を縮めて数だけの文節にしても、後ろの句読点は数の前に見えている文字列で決める（API 40 の後の 4, は I の側）
    @Test func punctuatesAfterAUserWordResizedToANumber() throws {
        let clauses = segmenter.clauses("API 404,")
        let word = try #require(clauses.firstIndex { $0.output.hasPrefix("Not Found") })
        let resized = segmenter.resize(segmenter.resize(clauses, at: word, by: -1), at: word, by: -1)
        #expect(resized.map(\.output).joined().hasSuffix(","))
        #expect(!resized.map(\.output).joined().contains("、"))
    }

    /// 文節の伸縮で登録した語の文節に戻したときも、後ろの句読点は区間の種類ではなく語の表記で形を決める（英語として登録した 円 の後は 、）
    @Test func punctuatesAfterAResizedUserWordByItsShownForm() {
        let resized = segmenter.resize(segmenter.resize(segmenter.clauses("jpy,"), at: 0, by: -1), at: 0, by: 1)
        #expect(resized.map(\.output).joined() == "円、")
    }

    /// 日本語として扱う語の区間の後ろの - は、その語の見えている最後の字で長音を判定する（すご の後ろは ー、Café の後ろは打ったまま）
    @Test func readsADashAfterAUserWordByItsShownLetter() {
        #expect(segmenter.candidates("cwd-desu").contains { $0.after == .word && $0.segment.kind == .japanese && $0.segment.reading == "ーです" })
        #expect(!segmenter.candidates("cafe-desu").contains { $0.after == .word && $0.segment.reading.hasPrefix("ー") })
    }

    /// 綴りの表で読める打鍵は、そのかなの語になり、長い打鍵の途中でも効く
    @Test func readsReadableKeysWithTheSpellingTable() {
        #expect(segmenter.liveText("ma-jannnomannzu").hasSuffix("萬子"))
    }

    /// 読めない打鍵は、英語の区間の綴りがちょうど一致したときの表記になる。打ったままの綴りは候補の 2 番目に残る
    @Test func showsTheRegisteredSpellingOfAnEnglishWord() throws {
        #expect(segmenter.liveText("githubdekoukaisuru").hasPrefix("GitHub"))
        let first = try #require(segmenter.clauses("githubdekoukaisuru").first)
        #expect(first.candidates.prefix(2) == ["GitHub", "github"])
    }

    /// 英語として扱う打鍵は、かな漢字変換に入れないので英語の語を割らない（nodes は Node.js と s にならない）
    @Test func keepsEnglishKeysOutOfKanaConversion() {
        #expect(segmenter.liveText("nodewoinsuto-rusuru").hasPrefix("Node.js"))
        #expect(segmenter.liveText("nodes") == "nodes")
    }

    /// 英語として扱う打鍵は、日本語として読める綴りでも英語の区間にする（tugime は継ぎ目にならない）
    @Test func makesEnglishKeysAnEnglishSpan() {
        #expect(segmenter.liveText("tugime") == "tugime")
        #expect(segmenter.liveText("tugimewotukau").hasPrefix("tugime"))
        #expect(segmenter.segment("tugimewotukau").first.map { [$0.source, "\($0.kind)"] } == ["tugime", "english"])
        // 数字で始まる打鍵も、区間全体で一致すれば英語の区間にする
        #expect(segmenter.liveText("2fa") == "2FA")
    }

    /// 英語の区間の末尾の n は打ったままの n として外さないので、かなに読めて n で終わる登録語（kanon）も表記どおりに見せる
    @Test func keepsTheTrailingNOfAnEnglishWord() {
        #expect(segmenter.liveText("kanon") == "Kanon")
    }

    /// 英語として登録した語の後に打った n は、語の表記を残して別の区間にする。n の区間は ん を選べる
    @Test func keepsTheRegisteredSpellingBeforeAPendingN() throws {
        #expect(segmenter.liveText("githubn") == "GitHubn")
        let n = try #require(segmenter.clauses("githubn").last)
        #expect(n.candidates.contains("ん"))
    }

    /// 日本語として扱う打鍵は、英語の語でもかな漢字変換に入れる。区切りが日本語に寄るのも登録に従う
    @Test func putsJapaneseKeysIntoKanaConversion() {
        #expect(segmenter.liveText("sakewonomu").hasPrefix("鮭"))
    }

    /// 日本語として扱う、かなに読めない打鍵は、打鍵とちょうど一致する区間をその語にし、日本語区間と同じく後ろに続ける
    @Test func makesUnreadableJapaneseKeysTheWord() throws {
        #expect(segmenter.liveText("cafe") == "Café")
        #expect(segmenter.liveText("cafedeyasumu").hasPrefix("Café"))
        let segments = segmenter.segment("cafedeyasumu")
        #expect(segments.map(\.kind) == [.word, .japanese])
        #expect(segments.map(\.reading) == ["cafe", "でやすむ"])
        let first = try #require(segmenter.clauses("cafedeyasumu").first)
        #expect(first.candidates.prefix(3) == ["Café", "cafe", "ｃａｆｅ"])
        // 英語の文節と同じく、打鍵をかなにできればかなとカタカナも選べる
        #expect(first.candidates.contains("かふぇ"))
        #expect(first.candidates.contains("カフェ"))
    }

    /// 文節の伸縮で打鍵を 1 区間として判定し直すときも、読めない日本語の打鍵はその語の区間にする
    @Test func makesUnreadableJapaneseKeysTheWordWhenResized() {
        let span = segmenter.singleSpan("cafe", context: .start, preceding: Segmenter.Preceding(nil))
        #expect(span.kind == .word)
        #expect(span.output == "Café")
    }

    /// 英語の後の句読点は英語区間に入るので、句読点で区切った綴りごとに引く
    @Test func showsTheRegisteredSpellingBeforePunctuation() {
        #expect(segmenter.liveText("github.") == "GitHub.")
        #expect(segmenter.liveText("github,node") == "GitHub,Node.js")
    }

    /// 登録した綴りを含むだけの別の綴り（githubs）は替えない
    @Test func keepsOtherSpellings() {
        #expect(segmenter.liveText("githubs").hasPrefix("githubs"))
    }
}
