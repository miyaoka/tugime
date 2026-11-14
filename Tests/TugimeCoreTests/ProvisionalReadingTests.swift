import Testing
@testable import TugimeCore

@Suite struct ProvisionalReadingTests {
    let table: RomajiTable

    init() throws {
        table = try Shared.table.get()
    }

    private func display(_ text: String) -> Segmenter.LiveDisplay {
        Segmenter.LiveDisplay(text: text, differsFromInput: false)
    }

    /// 変換が届く前の閉じ丸括弧は、区切りと同じく、届いた表示か入力欄の直前で閉じていない開き丸括弧と同じ形にする。
    /// 直前が英字でも全角の組なら全角、直前がかなでも半角の組なら半角。全角の閉じ丸括弧の後ろの句読点は、区切りと同じく日本語の記号
    @Test(arguments: [
        ("kyou (git)", "kyou (git", "今日 （git", "", "今日 （git）"),
        ("github (git)", "github (git", "github (git", "", "github (git)"),
        ("ame)", "", "", "Hello (", "あめ)"),
        ("kore(github),", "kore(github", "これ（github", "", "これ（github）、"),
    ])
    func closesABracketInTheShapeOfItsPartner(keys: String, convertedKeys: String, shown: String, leading: String, expected: String) {
        let converted = convertedKeys.isEmpty ? [] : [(keys: convertedKeys, display: display(shown))]
        #expect(Segmenter.liveDisplay(of: keys, converted: converted, leading: Segmenter.Leading(leading), table: table).text == expected)
    }

    @Test(arguments: [
        ("kar", true, "かr"),
        ("tyokk", true, "ちょkk"),
        ("seikakuni", true, "せいかくに"),
        // 句読点は直前が日本語なら日本語の記号、英字なら打ったまま
        ("nara,", true, "なら、"),
        (",", true, "、"),
        (",", false, ","),
        // 空白は直前の側を変えないので、空白の後の句読点は空白を飛ばした前で決まる
        (" (", true, " （"),
        (" (", false, " ("),
        ("nara (", true, "なら （"),
        // 記号の打鍵は前によらず記号
        ("[", false, "「"),
        ("shsi", false, "shし"),
        // 数の区切りは区切りと同じく打ったまま
        ("3.14", true, "3.14"),
        ("2026-11-03", true, "2026-11-03"),
        // 数字だけの読みは直前の側を変えない
        ("html5.", true, "html5."),
        ("3.", true, "3。"),
        ("nara3.", true, "なら3。"),
    ])
    func provisionalText(keys: String, afterJapanese: Bool, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, afterJapanese: afterJapanese, preceding: Segmenter.Preceding(nil), table: table, opened: []) == expected)
    }

    /// 入力の先頭の数の区切りは、直前の文字（入力欄や前の表示）が数字かで決める
    @Test(arguments: [(".14", "3", ".14"), ("-11-03", "2026", "-11-03"), (".", "3", "。")])
    func readsANumberSeparatorAfterThePrecedingDigits(keys: String, preceding: String, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, afterJapanese: true, preceding: Segmenter.Preceding(preceding.last), table: table, opened: []) == expected)
    }

    /// 届いた変換の後ろに打った - は、その変換の見えている最後の文字が日本語の文字（漢字を含む）なら ー、英字なら打ったまま
    @Test(arguments: [("ninnki-", "ninnki", "人気", "人気ー"), ("ra-", "ra", "ら", "らー"), ("node-", "node", "node", "node-")])
    func readsADashAfterTheConvertedDisplay(keys: String, base: String, shown: String, expected: String) {
        let live = Segmenter.liveDisplay(of: keys, converted: [(base, display(shown))], leading: .start, table: table)
        #expect(live.text == expected)
    }

    /// 末尾の単独の n は打ったまま。nn、後ろに打鍵が続く n、綴りの組の一部の n（xn）は読む
    @Test(arguments: [("n", "n"), ("bn", "bn"), ("ka,n", "か、n"), ("kon", "こn"), ("nn", "ん"), ("konnn", "こんn"), ("kona", "こな"), ("xn", "ん")])
    func keepsAPendingNAsTyped(keys: String, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, afterJapanese: true, preceding: Segmenter.Preceding(nil), table: table, opened: []) == expected)
    }

    @Test(arguments: [
        // 打ちかけの子音は表示から外して読み直す
        ("g", "g", "", 1),
        ("github", "github", "githu", 1),
        ("githubにpush", "githubnipush", "githubにpu", 2),
        ("してh", "siteh", "して", 1),
        // 表示に打ったまま出た末尾の n も外す
        ("幕張n", "makuharin", "幕張", 1),
        ("python", "python", "pytho", 1),
        // 母音や nn で終われば外さない
        ("設定を", "setteiwo", "設定を", 0),
        ("本", "honn", "本", 0),
        ("感k", "kannk", "感", 1),
    ])
    func splitsPending(shown: String, keys: String, kept: String, pending: Int) throws {
        let split = try #require(Segmenter.splitPending(shown, typed: keys, table: table))
        #expect(split.kept == kept)
        #expect(split.pending == pending)
    }

    @Test func cannotSplitWhenPendingIsInsideAWord() {
        #expect(Segmenter.splitPending("ん", typed: "xn", table: table) == nil)
    }

    /// 登録語（cafe を Café）の後の n も打ったまま
    @Test func keepsPendingNAfterARegisteredWordBeforeConversionArrives() {
        let base = Segmenter.LiveDisplay(text: "Café", differsFromInput: false)
        let shown = Segmenter.liveDisplay(of: "cafen", converted: [("cafe", base)], leading: .start, table: table)
        #expect(shown.text == "Cafén")
    }

    @Test(arguments: [
        // 同じ打鍵列の変換が届いていればそれ
        ("githubni", [("githubni", "githubに")], "", "githubに"),
        // 先頭に当たる最新の変換から打ちかけを外し、後の打鍵とまとめて読む
        ("githubni", [("github", "github")], "", "githubに"),
        ("gi", [("g", "g")], "", "ぎ"),
        ("teno", [("te", "て"), ("ten", "点")], "", "ての"),
        // Backspace で前の打鍵列に戻ったときも、届いている変換を使う
        ("make", [("make", "make"), ("makes", "makes")], "", "make"),
        // 届いていなければ打鍵列全体を読む。先頭の句読点は入力欄の直前で決める
        (",", [], "今日は", "、"),
        (",", [], "make", ","),
        // 読み終えた nn の n は読み直さない（英語として登録した konn の Konn）
        ("konna", [("konn", "Konn")], "", "Konnあ"),
        // 綴りの表で xn が組になる xnn の最後の n は単独なので、次の打鍵と読み直す
        ("kaxnna", [("kaxnn", "艦n")], "", "艦な"),
    ])
    func liveDisplay(keys: String, converted: [(String, String)], before: String, expected: String) {
        let shown = Segmenter.liveDisplay(
            of: keys, converted: converted.map { ($0.0, display($0.1)) }, leading: Segmenter.Leading(field: before), table: table
        )
        #expect(shown.text == expected)
    }

    /// Backspace は見えている最後の 1 文字を、利用者が打ったかなの単位で、その下の打鍵ごと消す。残りは表示のまま
    @Test(arguments: [
        // かなは最後の 1 単位。小書きのかなは前のかなと 1 単位
        ("toukyouniiku", "東京に行く", "toukyounii", "東京に行"),
        ("makewosuru", "makeをする", "makewosu", "makeをす"),
        ("kyo", "きょ", "", ""),
        ("ra-menn", "ラーメン", "ra-me", "ラーメ"),
        // 1 文字の漢字はその読み
        ("toukyounii", "東京に行", "toukyouni", "東京に"),
        // 2 文字以上の漢字の連なりは、読みのかなに戻して最後の単位を消す
        ("kyou", "今日", "kyo", "きょ"),
        ("tokkyo", "特許", "toxtu", "とっ"),
        ("nihonn", "日本", "niho", "にほ"),
        // 残る ん は、続けて打つかなの綴りによらず ん と読める綴りにする
        ("kanji", "漢字", "kann", "かん"),
        ("denwa", "電話", "denn", "でん"),
        // っち は っ と ち の 2 単位
        ("kotchi", "こっち", "koxtu", "こっ"),
        // 残る っ は、続けて打つかなの綴りによらず っ と読める綴りにする
        ("bassi", "抜歯", "baxtu", "ばっ"),
        ("sitta", "知った", "sixtu", "知っ"),
        ("toxtu", "とっ", "to", "と"),
        // 句読点と記号は 1 文字
        ("sitta.", "知った。", "sitta", "知った"),
        ("toukyou.", "東京。", "toukyou", "東京"),
        ("ka[", "か「", "ka", "か"),
        // 句読点の前で ん と読まれた単独の n は、句読点を消しても ん のまま
        ("n.", "ん。", "nn", "ん"),
        ("nihon.", "日本。", "nihonn", "日本"),
        ("ra-men.", "ラーメン。", "ra-menn", "ラーメン"),
        // 英語の区間の n は打ったまま
        ("kotlin[", "kotlin「", "kotlin", "kotlin"),
        // 句読点・記号・英字・数字の後ろの漢字は、その後ろの打鍵の読みだけと照らす
        ("toukyou,oosaka", "東京、大阪", "toukyou,oosa", "東京、おおさ"),
        ("6ji", "6時", "6", "6"),
        ("githubue", "github上", "github", "github"),
        // 英字の打鍵と同じ字が後ろの漢字の打鍵にもある
        ("datakanri", "data管理", "datakann", "dataかん"),
        ("datakan", "data感", "data", "data"),
        // 英字と打ちかけは 1 打鍵
        ("make", "make", "mak", "mak"),
        ("toukyouniik", "東京に行k", "toukyounii", "東京に行"),
        ("hon", "ほn", "ho", "ほ"),
    ])
    func deletesTheLastShownKana(keys: String, shown: String, expectedKeys: String, expectedText: String) {
        let deleted = Segmenter.deletingLastShown(of: keys, shown: shown, leading: .start, table: table)
        #expect(deleted?.keys == expectedKeys)
        #expect(deleted?.text == expectedText)
    }

    /// 残した っ の後は、どの綴りを続けても っ に続けて読む
    @Test(arguments: [("toxtukyo", "とっきょ"), ("baxtusi", "ばっし"), ("baxtukinn", "ばっきん"), ("kannji", "かんじ")])
    func readsOnAfterAKeptSokuon(keys: String, expected: String) {
        #expect(Segmenter.provisionalText(of: keys, afterJapanese: true, preceding: Segmenter.Preceding(nil), table: table, opened: []) == expected)
    }

    /// 表示の字に対応する打鍵が決まらなければ、表示を残せない
    @Test(arguments: [
        // 表示のかなが打鍵の読みと合わない
        ("toukyouniiku", "東京に行け"),
        // 日本語の語に登録した英字の表記。末尾の i が打鍵の末尾とたまたま一致しても、打ったままの字ではない
        ("kanji", "Fiji"),
    ])
    func refusesAShownCharacterWithoutItsKeys(keys: String, shown: String) {
        #expect(Segmenter.deletingLastShown(of: keys, shown: shown, leading: .start, table: table) == nil)
    }

    /// 表示を残せないときは、打ったかなの最後の単位を消す。英語の区間の字と、打ちかけで終わる打鍵は 1 打鍵
    @Test(arguments: [
        // 利用者の辞書の語の表記は打鍵と対応しない。区間の種類が分かればそれで決める
        ("yorosiku", "よろしくお願いします", false, "yorosi"),
        ("kanji", "Fiji", false, "kann"),
        ("kube", "Kubernetes", true, "kub"),
        // 区間の種類が分からない表示では、英語の区間に登録した表記は、大文字と小文字を除けば打ったまま
        ("api", "API", nil, "ap"),
        ("kanji", "Fiji", nil, "kann"),
        ("kak", "かk", nil, "ka"),
    ] as [(String, String, Bool?, String)])
    func deletesTheLastTypedKana(keys: String, shown: String, endsInEnglish: Bool?, expected: String) {
        #expect(Segmenter.deletingLastTyped(of: keys, shown: shown, endsInEnglish: endsInEnglish, leading: .start, table: table) == expected)
    }
}
