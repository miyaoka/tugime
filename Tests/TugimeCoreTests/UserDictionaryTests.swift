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

/// 本物の変換器に利用者の語を入れる。テストで共有する変換器（SegmenterTests の Shared）の辞書を変えないよう、別に作る
@Suite struct UserWordConversionTests {
    let converter = ConversionMethod.baseline.make()

    /// 入力全体が利用者の語 1 つでも、カタカナにしただけの候補と同じ品詞なのに捨てない
    @Test func convertsAndListsTheUserWord() throws {
        try converter.replaceUserWords([UserWord(reading: "いーそう", word: "一索")])
        let reading = try #require(converter.convert(kana: "いーそう", context: .start))
        #expect(reading.text == "一索")
        #expect(reading.clauses.map(\.userWords) == [[UsedUserWord(reading: "イーソウ", spellings: ["一索"])]])
        #expect(converter.alternatives(kana: "いーそう", context: .start).contains("一索"))
    }

    /// 前に名詞を置いて読む文脈でも、利用者の語は前に置いたものを外した文節に付く
    @Test func marksTheUserWordAfterAStandIn() throws {
        try converter.replaceUserWords([UserWord(reading: "いーそう", word: "一索")])
        let reading = try #require(converter.convert(kana: "いーそうをきる", context: .afterWord))
        #expect(reading.clauses.flatMap(\.userWords).map(\.spellings) == [["一索"]])
        #expect(reading.text.hasPrefix("一索"))
    }

    /// 使った語には、同じ読みに登録した表記をすべて添える。表示はそのどれかを含めばよい
    @Test func listsEverySpellingOfTheReading() throws {
        try converter.replaceUserWords([UserWord(reading: "まんず", word: "萬子"), UserWord(reading: "まんず", word: "マンズ")])
        let reading = try #require(converter.convert(kana: "まんず", context: .start))
        #expect(reading.clauses.flatMap(\.userWords).map(\.spellings) == [["萬子", "マンズ"]])
        let listed = converter.alternatives(kana: "まんず", context: .start)
        #expect(listed.contains("萬子") && listed.contains("マンズ"))
    }

    /// ゕ ゖ の読みも、打った読みと同じ規則でカタカナにして引く（azooKey は ゕ を ヵ にして辞書を引く）
    @Test func findsAReadingWithSmallKa() throws {
        try converter.replaceUserWords([UserWord(reading: "いっゕげつ", word: "壱ヶ月")])
        #expect(converter.alternatives(kana: "いっゕげつ", context: .start).contains("壱ヶ月"))
    }

    /// 変換器を作ると、終わったプロセスが残した辞書のディレクトリを消し、動いているプロセスのものは残す
    @Test func removesDirectoriesLeftByFinishedProcesses() throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tugime-user-dictionary", isDirectory: true)
        let left = root.appendingPathComponent("\(finished.processIdentifier)-left", isDirectory: true)
        let alive = root.appendingPathComponent("\(getpid())-alive", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: alive) }
        _ = ConversionMethod.baseline.make()
        #expect(!FileManager.default.fileExists(atPath: left.path))
        #expect(FileManager.default.fileExists(atPath: alive.path))
    }

    /// 5000 語でも組み立てられ、入れた語を引ける
    @Test func findsWordsInALargeDictionary() throws {
        let digits = Array("あいうえおかきくけこ")
        let words = (0..<5000).map { n in UserWord(reading: "ゆーざー" + String(String(n).map { digits[$0.wholeNumberValue!] }), word: "語\(n)") }
        try converter.replaceUserWords(words + [UserWord(reading: "いーそう", word: "一索")])
        #expect(converter.convert(kana: "いーそう", context: .start)?.text == "一索")
        #expect(converter.alternatives(kana: "ゆーざーいおう", context: .start).contains("語142"))
    }

    /// 置き換えると前の語は消える。採点のセッションが前の辞書の途中の計算を使い回さない
    @Test func replacingDropsThePreviousWords() throws {
        try converter.replaceUserWords([UserWord(reading: "いーそう", word: "一索")])
        #expect(converter.convert(kana: "いーそう", context: .start)?.text == "一索")
        try converter.replaceUserWords([])
        let reading = try #require(converter.convert(kana: "いーそう", context: .start))
        #expect(reading.text != "一索")
        #expect(reading.clauses.flatMap(\.userWords).isEmpty)
    }
}

/// 打鍵で登録した辞書を、区切りに入れる。共有する区切り（SegmenterTests の Shared）の辞書を変えないよう、別に作る
@Suite struct UserDictionarySegmenterTests {
    let segmenter: Segmenter

    init() throws {
        segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: ConversionMethod.baseline.make())
        try segmenter.replaceUserDictionary(UserDictionary(contents: "mannzu\t萬子\ngithub\tGitHub\nnode\tNode.js\ntugime\ttugime\nsake\t鮭\tja\ncafe\tCafé"))
    }

    /// 綴りの表で読める打鍵は、そのかなの語になり、長い打鍵の途中でも効く
    @Test func readsReadableKeysWithTheSpellingTable() {
        #expect(segmenter.liveText("ma-jannnomannzu").hasSuffix("萬子"))
    }

    /// 読めない打鍵は、英語の区間の綴りがちょうど一致したときの表記になる。打ったままの綴りは候補の 2 番目に残る
    @Test func showsTheRegisteredSpellingOfAnEnglishWord() throws {
        #expect(segmenter.liveText("githubdekoukaisuru").hasPrefix("GitHubで"))
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
        #expect(segmenter.liveText("tugimewotukau").hasPrefix("tugimeを"))
    }

    /// 日本語として扱う打鍵は、英語の語でもかな漢字変換に入れる。区切りが日本語に寄るのも登録に従う
    @Test func putsJapaneseKeysIntoKanaConversion() {
        #expect(segmenter.liveText("sakewonomu").hasPrefix("鮭を"))
    }

    /// 日本語として扱う、かなに読めない打鍵は、打鍵とちょうど一致する区間をその語にし、日本語区間と同じく後ろに続ける
    @Test func makesUnreadableJapaneseKeysTheWord() throws {
        #expect(segmenter.liveText("cafe") == "Café")
        #expect(segmenter.liveText("cafedeyasumu").hasPrefix("Caféで"))
        #expect(segmenter.liveText("cafe,") == "Café、")
        let first = try #require(segmenter.clauses("cafedeyasumu").first)
        #expect(first.candidates.prefix(2) == ["Café", "cafe"])
    }

    /// 文節の伸縮で打鍵を 1 区間として判定し直すときも、読めない日本語の打鍵はその語の区間にする
    @Test func makesUnreadableJapaneseKeysTheWordWhenResized() {
        let span = segmenter.singleSpan("cafe", context: .start)
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
