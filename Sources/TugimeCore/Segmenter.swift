import Foundation

public struct Segment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        /// 入力を切った句読点（Segmenter.punctuation）と記号の打鍵（Segmenter.symbols）。組の開き括弧に合わせて半角にした閉じ括弧も含む
        case punctuation
        /// 利用者の辞書で日本語にした、かなに読めない打鍵（cafe を Café）。日本語区間と同じく前後に続き、表記は登録した語
        case word
    }

    public var kind: Kind
    /// 打鍵列のうちこの区間に当たる部分
    public var source: String
    /// 日本語ならかな、英語なら打鍵列そのまま
    public var reading: String
    /// 確定する文字列
    public var output: String
    public var score: Double
    /// この位置のかなを変換する文脈。日本語区間は変換で読んだ文脈（カーソルの前に続く形は文頭か前の語に続く形に決まる）、
    /// 英語区間はその綴りをかなとして読むときに求める文脈
    public var context: JapaneseContext
}

/// 区切りの採点で比べた区間の候補。start と end は入力全体の文字の位置
public struct ScoredSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int
    /// 直前の区間の種類。入力の先頭か、日本語の記号の後なら nil
    public var after: Segment.Kind?
    public var segment: Segment
}

/// 打鍵列の全体を、日本語区間と英語区間の並びとして最も自然に読める区切りに分ける。
/// 綴りの表で読めない箇所は日本語区間に入れられないので、そこは必ず英語になる。
/// 読める箇所は、日本語として変換した評価値と英語の綴りとしての評価値を比べて決める。
public final class Segmenter {
    public let table: RomajiTable
    let english: EnglishModel
    let japaneseConverter: any JapaneseConverting
    /// 利用者の辞書で英語として扱う打鍵ごとの表記。ファイルの行の順に持つ
    var typedWords: [String: [String]] = [:]
    /// 利用者の辞書で日本語として扱う、かなに読めない打鍵ごとの表記。ファイルの行の順に持つ
    var typedJapaneseWords: [String: [String]] = [:]
    /// Backspace で残した表示のうち、日本語区間の表示（keepDisplay）。表示の変換より先に引く。未確定の文字列の寿命だけ持つ
    var keptDisplays: [KeptDisplayKey: JapaneseDisplay] = [:]

    /// 日本語区間の表示を決めるもの。表示の変換と同じく、区間の読み・文脈・左の文字列
    struct KeptDisplayKey: Hashable {
        var kana: String
        var context: JapaneseContext
        var left: String
    }
    /// 英語の綴りの評価値を、日本語の変換の評価値と同じ尺度に揃える倍率
    static let englishWeight = 1.4
    /// 日本語の区間を 1 つ増やすごとに引く値
    static let japaneseSpanPenalty = 3.0
    /// 日本語区間に続く日本語区間で引く値
    static let continuingJapanesePenalty = 2.0
    /// 英語の区間を 1 つ増やすごとに引く値。負なので、英語の区間は増やすほど点が上がる
    static let englishSpanPenalty = -2.0
    /// 空白で区切って打った語の全体を英語区間にする候補に足す値
    static let spacedEnglishBonus = japaneseSpanPenalty
    /// 英字が 1 文字だけの英語の区間で、さらに引く値
    static let singleLetterEnglishPenalty = 3.0
    /// 利用者の辞書で英語として扱う打鍵の区間の評価値の下限と、日本語として扱う読めない打鍵の区間の評価値。
    /// かな漢字変換に入れた利用者の語 1 つの点の基準（登録数による減点と前後の連接を除いたもの）から作り、登録数によらず一定にする
    static let registeredScore = LatticeConverter.userWordValue - japaneseSpanPenalty

    public init(table: RomajiTable, english: EnglishModel, japanese: any JapaneseConverting) {
        self.table = table
        self.english = english
        self.japaneseConverter = japanese
    }

    /// 入力の前にあるもの。入力欄のカーソルより前の文字列（読めた分）
    public struct Leading: Sendable, Equatable {
        public var text: String

        public init(_ text: String) {
            self.text = text
        }

        /// 前に何も無い
        public static let start = Leading("")

        /// 入力欄から読む、カーソルより前の文字列の長さの上限（UTF-16 の単位）。表示の変換が左の文脈に使う長さ（ZenzPrompt.maxContextLength）を超えない。
        /// モデルに渡すのは、そのうちモデルが学習した列の長さに収まる分だけで、残りは表示の変換が前から削る
        public static let maxLength = 200

        /// 入力欄のカーソルより前の文字列を、UTF-16 で maxLength 単位まで読む。caret はカーソルの UTF-16 の位置、
        /// substring は入力欄の UTF-16 の範囲の文字列を返すもので、読めなければ nil を返す。読めなければ前に何も無いとする。
        /// 途中から読んだときは、範囲の先頭がサロゲートペアや結合文字の途中に当たりうるので、先頭の 1 文字を捨てる
        public init(caret: Int, substring: (NSRange) -> String?) {
            let length = min(caret, Self.maxLength)
            guard length > 0, let text = substring(NSRange(location: caret - length, length: length)) else {
                self = .start
                return
            }
            self.init(length < caret ? String(text.dropFirst()) : text)
        }

        /// 入力欄の文字列が field で、カーソルがその末尾にあるとき。入力メソッドと同じく init(caret:substring:) で読む
        public init(field: String) {
            let text = field as NSString
            self.init(caret: text.length) { text.substring(with: $0) }
        }

        /// 入力が前の文字列のどこに続くか
        var continuation: Continuation { Continuation(after: text) }

        /// 入力の先頭の句読点を打ったままにするか。後ろが文の頭か（continuation）とは別に、前の文字列の直前の文字で決める
        var keepsPunctuationTyped: Bool { Segmenter.keepsPunctuationTyped(afterText: text) }

        /// 入力の最初の日本語区間の評価のしかた。前の文字列が、末尾の空白を飛ばして数字で終わるなら、未確定の文字列の中の数字の後と同じく、その数字に続く形にする。
        /// 確定してから続きを打っても、まとめて打ったときと同じ評価になる
        var japaneseContext: JapaneseContext {
            let afterText = Segmenter.context(after: Segmenter.droppingTrailingSpaces(text))
            if case .afterNumber = afterText { return afterText }
            return continuation.japaneseContext
        }
    }

    /// 入力が前の文字列のどこに続くか
    enum Continuation: Equatable {
        /// 文頭。前に何も無いか、改行などの空白（" " は飛ばす）・文末の記号の後
        case start
        /// 日本語の文の途中
        case afterJapanese
        /// ラテン文字・ASCII の記号など、日本語でない文字の後
        case afterEnglish

        /// 前の文字列の、末尾の空白を飛ばした最後の文字から決める。無い、改行などの空白、文末の記号の後なら文頭、残りは句読点を打ったままにする側
        /// （keepsPunctuationTyped(afterText:)）なら英語の後、日本語の記号にする側なら日本語の後。空白をはさんでも、数で終わっても、その前の文字で決まる
        init(after spaced: String) {
            let text = Segmenter.droppingTrailingSpaces(spaced)
            let startsSentence = Segmenter.numberLength(text.reversed()) == 0
                && text.last.map { $0.isWhitespace || $0.unicodeScalars.contains(where: \.properties.isSentenceTerminal) } ?? true
            if startsSentence {
                self = .start
                return
            }
            self = Segmenter.keepsPunctuationTyped(afterText: text) ? .afterEnglish : .afterJapanese
        }

        /// 最初の日本語区間の評価のしかた
        var japaneseContext: JapaneseContext { self == .start ? .start : .afterCaret }
    }

    /// 区間の後ろの句読点を打ったままにするか。入力欄の直前と変換が届く前の表示と同じく、表記を前の文字列として keepsPunctuationTyped(afterText:) で決める。
    /// 英語の区間と利用者の辞書の語の区間は、登録した表記によって日本語の文字で終わることも英字で終わることもある（第2、PWD）。
    /// 日本語区間は区切りの時点で表示の変換の表記が決まっていないので、日本語の側とする
    static func keepsPunctuationTyped(after segment: Segment) -> Bool {
        segment.kind != .japanese && keepsPunctuationTyped(afterText: segment.output)
    }

    /// segments のうち、数だけの日本語区間を除いた最後の区間。数は日本語でも英語でもないので、句読点の形は数の前の区間で決める。
    /// 数字だけの打鍵で登録した英語の語（404 → Not Found）は数ではなく語なので除かない
    static func lastWord(in segments: [Segment]) -> Segment? {
        segments.last { !isNumberSpan($0) }
    }

    /// 数だけの日本語区間か
    static func isNumberSpan(_ segment: Segment) -> Bool {
        segment.kind == .japanese && isNumber(segment.source)
    }

    /// text の後ろの句読点を打ったままにするか。末尾の空白と数を、どちらも無くなるまで飛ばした最後の文字が、ASCII の英字・記号かラテン文字（isLatinSide）なら打ったまま、
    /// それ以外（かな・漢字・全角の記号・※ などの記号・絵文字）、改行、何も無いなら日本語の記号にする。数は日本語でも英語でもないので、その前の文字の側に付く（API 5 は I、今日 3 5 は 日）。
    /// 後ろが文の頭か（Continuation）とは別に決める。英語の文の途中の . ! ? の後ろ（wait... really?!）は文の頭ではなく英語の続き
    static func keepsPunctuationTyped(afterText spaced: String) -> Bool {
        var text = droppingTrailingSpaces(spaced)
        while case let number = numberLength(text.reversed()), number > 0 {
            text = droppingTrailingSpaces(String(text.dropLast(number)))
        }
        guard let last = text.last else { return false }
        return isLatinSide(last)
    }

    /// 後ろの句読点を打ったままにする文字か。空白でない ASCII の字と、Unicode の文字種がラテン文字（Script=Latin）の文字（é ü ß）。
    /// ASCII かは字全体で見る（キーキャップの絵文字 1️⃣ は ASCII の 1 に記号が重なった字なので含めない）。
    /// ラテン文字の区画にあっても文字でない字（ローマ数字 Ⅲ）と、全角形の英字（Ａ。日本語の文章で使う形）は含めない
    static func isLatinSide(_ c: Character) -> Bool {
        guard !c.isWhitespace, let base = c.unicodeScalars.first else { return false }
        if c.isASCII { return true }
        if (0xFF00...0xFFEF).contains(base.value) { return false }
        // ローマ数字は Alphabetic なので Character.isLetter では外れない。一般カテゴリで文字（L）かを見る
        switch base.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: break
        default: return false
        }
        // 正規表現の Unicode 属性は、Character には最初の scalar で当たる
        return String(c).wholeMatch(of: #/\p{Script=Latin}/#) != nil
    }

    /// 末尾の空白（" "）を除いた文字列。改行は除かない
    static func droppingTrailingSpaces(_ text: String) -> String {
        String(text.reversed().drop { $0 == " " }.reversed())
    }

    /// 英語区間に続く日本語区間の評価のしかた。英語区間が数（numberLength）で終わるなら、その数に続く形（1500 円、3.5 倍）にする
    static func context(after text: some Collection<Character>) -> JapaneseContext {
        let number = String(text.suffix(numberLength(text.reversed())))
        return number.isEmpty ? .afterWord : .afterNumber(number)
    }

    /// chars の先頭から続く数の長さ。数は数字の連なりと、数字にはさまれた numberSeparators（3.14 1,000 10:30）。数で始まらなければ 0。
    /// 前後どちらから数えても同じ長さになる
    static func numberLength(_ chars: some Sequence<Character>) -> Int {
        var length = 0
        var pending = 0
        for c in chars {
            if isDigit(c) {
                length += pending + 1
                pending = 0
            } else if length > 0, pending == 0, numberSeparators.contains(c) {
                pending = 1
            } else {
                break
            }
        }
        return length
    }

    /// text 全体が 1 つの数か
    static func isNumber(_ text: some Collection<Character>) -> Bool {
        !text.isEmpty && numberLength(text) == text.count
    }

    /// ASCII の数字か
    static func isDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    /// 数字にはさまれたとき、入力を切らず数の一部として打ったまま残す記号（3.14 1,000 10:30 0120-345-678）
    static let numberSeparators: Set<Character> = [".", ",", ":", "-"]

    /// chars[i] が数の一部として打ったまま残す記号か。前の文字は、i が 0 なら before（入力欄や前の文節の最後の文字）
    static func isNumberSeparator(at i: Int, in chars: [Character], before: Character?) -> Bool {
        guard numberSeparators.contains(chars[i]), i + 1 < chars.count, isDigit(chars[i + 1]) else { return false }
        return (i > 0 ? chars[i - 1] : before).map(isDigit) == true
    }

    /// 読む打鍵の直前。数の区切り（isNumberSeparator）は直前の打鍵 key で、長音（lengthensOnlyJapanese）は直前に見えている文字 shown で決める。
    /// 前の文節や届いた変換の後ろでは、打鍵（ASCII）と見えている文字（かなや漢字）が違う
    struct Preceding {
        let key: Character?
        let shown: Character?

        init(key: Character?, shown: Character?) {
            self.key = key
            self.shown = shown
        }

        /// 打鍵と見えている文字が同じとき（入力欄の文字、記号の打鍵）
        init(_ character: Character?) {
            self.init(key: character, shown: character)
        }
    }

    /// 長音は直前の音を伸ばす記号なので、日本語の文字（isJapaneseLetter）の後ろでだけ読める。kana の長音がどれもそうなっているか。
    /// shown は kana の直前に見えている文字
    static func lengthensOnlyJapanese(_ kana: String, after shown: Character?) -> Bool {
        var previous = shown
        for c in kana {
            if c == "ー", previous.map(isJapaneseLetter) != true { return false }
            previous = c
        }
        return true
    }

    /// 長音が伸ばせる日本語の文字か。ひらがな・カタカナ（長音を含む）・半角カタカナと、Unicode の文字種が漢字（Script=Han。々 を含む）の字。
    /// 中黒・濁点・踊り字など、かなの区画にあっても音を持たない記号は含めない。
    /// 基底の字で決めるので、濁点や半濁点が結合した字（ｺﾞ、か + U+3099）も含む
    static func isJapaneseLetter(_ c: Character) -> Bool {
        guard let base = c.unicodeScalars.first else { return false }
        if kanaRanges.contains(where: { $0.contains(base.value) }) { return true }
        // 正規表現の Unicode 属性は、Character には最初の scalar で当たる
        return String(c).wholeMatch(of: #/\p{Script=Han}/#) != nil
    }

    private static let kanaRanges: [ClosedRange<UInt32>] = [
        0x3041...0x3096, // ひらがな
        0x30A1...0x30FA, // カタカナ
        0x30FC...0x30FC, // 長音
        0xFF66...0xFF9D, // 半角カタカナ（半角の長音を含む）
    ]

    /// start から日本語として読み切れる終端ごとのかな。綴りの表で読み、数字にはさまれた numberSeparators は打ったまま読みに入れる（3.14 は 3.14）。
    /// 日本語の文字の後ろにない - を ー と読む読み（3- や us-west の -）は除く。start が 0 なら直前は before（入力欄や前の文節）、
    /// 0 より後なら直前の打鍵（ASCII なので、そこから ー では始まらない）
    static func japaneseReadings(table: RomajiTable, from start: Int, in chars: [Character], before: Preceding) -> [(end: Int, kana: String)] {
        let preceding = start > 0 ? Preceding(chars[start - 1]) : before
        var found: [Int: String] = [:]
        var pending: [(position: Int, kana: String)] = [(start, "")]
        while let (position, prefix) = pending.popLast() {
            for reading in table.readings(from: position, in: chars) where found[reading.end] == nil {
                let kana = prefix + reading.kana
                guard lengthensOnlyJapanese(kana, after: preceding.shown) else { continue }
                found[reading.end] = kana
                if reading.end < chars.count, isNumberSeparator(at: reading.end, in: chars, before: before.key) {
                    pending.append((reading.end + 1, kana + String(chars[reading.end])))
                }
            }
        }
        return found.sorted { $0.key < $1.key }.map { (end: $0.key, kana: $0.value) }
    }

    /// 綴り全体を日本語として読み切れればかな
    static func japaneseReading(table: RomajiTable, of text: some StringProtocol, before: Preceding) -> String? {
        let chars = Array(text)
        return japaneseReadings(table: table, from: 0, in: chars, before: before).first { $0.end == chars.count }?.kana
    }

    /// liveDisplay の文字列
    public func liveText(_ input: String, leading: Leading = .start) -> String {
        liveDisplay(input, leading: leading).text
    }

    /// 打っている途中に見せる文字列と、それが打った読みと合わない変換を含むか
    public struct LiveDisplay: Sendable, Equatable {
        /// differsFromInput のとき、入力メソッドが未確定の文字列の下に出す文言
        public static let warning = "入力と違う変換"
        /// Enter で確定するのもこれ
        public var text: String
        /// 変換して見せた日本語区間のどれかが、読みと対応づかない（JapaneseDisplay.matchesReading が偽）
        public var differsFromInput: Bool
        /// 最後の区間が英語の区間か。区切りの結果から作った表示だけが知る。変換の届いていない打鍵をつないだ表示と、Backspace で切った表示では nil
        public var endsInEnglish: Bool? = nil
    }

    /// 打っている途中に見せる文字列。日本語区間は変換し、英語区間は打ったまま。末尾の単独の n は打ったまま見せる（keepingPendingN）。
    /// 前の文字列は、区切りの評価と、表示の変換の左の文脈に使う
    public func liveDisplay(_ input: String, leading: Leading = .start) -> LiveDisplay {
        let (segments, pendingN) = keepingPendingN(segment(input, leading: leading))
        let shown = displays(of: segments.map(ShownSpan.init), left: leading.text, startsAtHead: true, endsInput: true, endsWithPendingN: pendingN) { index, display, _ in
            let text = display?.text ?? segments[index].output
            return (result: (display: display, text: text), shown: text)
        }
        return LiveDisplay(
            text: shown.map(\.text).joined(), differsFromInput: shown.contains { $0.display?.matchesReading == false },
            endsInEnglish: segments.last.map { $0.kind == .english }
        )
    }

    /// 表示の変換にかける 1 区間。日本語区間は表示の変換で表記を決める。それ以外の区間に表示する文字列は、displays の make が決める。
    /// どの区間も、後ろが文の頭か（startsSentence）を持つ。句読点と記号の打鍵は、日本語の記号にしたなら後ろが文の頭になる。
    /// 組に合わせて半角にした閉じ括弧の後ろは英語の後で、文の頭ではない。日本語区間も、文節の伸縮で句読点か記号をまたいでまとめ、
    /// 記号で終わるなら後ろが文の頭になる
    enum ShownSpan {
        case japanese(kana: String, context: JapaneseContext, startsSentence: Bool)
        case other(startsSentence: Bool)

        init(_ segment: Segment) {
            switch segment.kind {
            case .japanese: self = .japanese(kana: segment.reading, context: segment.context, startsSentence: false)
            case .punctuation: self = .other(startsSentence: Segmenter.continuation(after: segment.source, mark: segment.output) != .afterEnglish)
            case .english, .word: self = .other(startsSentence: false)
            }
        }

        /// この区間の後ろが文の頭か
        var startsSentence: Bool {
            switch self {
            case .japanese(_, _, let startsSentence), .other(let startsSentence): startsSentence
            }
        }
    }

    /// 区間を前から順に表示の変換にし、区間ごとに make で結果を作る。日本語区間は、left にそれより前の区間の表示をつないだものを左の文脈にする。
    /// make は、区間の番号・その表示の変換（日本語区間でなければ nil）・それより前に表示している文字列から、区間の結果と、その区間に実際に表示する
    /// 文字列を返す。表示する文字列は後ろの区間の左の文脈になるので、利用者が選んだ表記があればそれを含める。返す配列は spans と同じ順。
    /// 末尾の区間（endsWithPendingN なら、最後の打ったままの n の手前）が文の頭（入力の最初の区間か、日本語の記号にした句読点・記号の直後）の
    /// 1 かなだけなら、続けて打つ語の先頭なので、変換せずにかなのまま見せる（ki は 気 ではなく き、kon は こn）。
    /// startsAtHead は spans の最初が文の頭（入力の最初か、日本語の記号にした句読点・記号の直後）か。endsInput は spans の最後が入力の終わりか
    /// （文節の伸縮で、後ろに残す区間の手前までを渡すときは偽）。偽なら、末尾の 1 かなも続けて打つ語の先頭ではないので変換する
    func displays<Result>(
        of spans: [ShownSpan], left: String, startsAtHead: Bool, endsInput: Bool, endsWithPendingN: Bool,
        make: (Int, JapaneseDisplay?, String) -> (result: Result, shown: String)
    ) -> [Result] {
        var shown = left
        let lastSpan = endsInput ? spans.count - (endsWithPendingN ? 2 : 1) : nil
        return spans.enumerated().map { index, span in
            let display: JapaneseDisplay? = switch span {
            case .other:
                nil
            case .japanese(let kana, let context, _):
                if let kept = keptDisplays[KeptDisplayKey(kana: kana, context: context, left: shown)] {
                    kept
                } else if index == lastSpan && (index == 0 ? startsAtHead : spans[index - 1].startsSentence) && kana.count == 1 {
                    JapaneseDisplay(text: kana, clauses: [JapaneseClause(reading: kana, text: kana)])
                } else {
                    japaneseConverter.display(kana: kana, context: context, left: shown)
                }
            }
            let made = make(index, display, shown)
            shown += made.shown
            return made.result
        }
    }

    /// この長さ以下の読める綴りは、英語の語であっても日本語として読む
    static let maxJapaneseFirstLength = 2

    /// 英語区間を、空白で区切った語ごとにかなにしたもの（RomajiTable.typedKana）。打ったまま残る文字がある語は打ったまま、空白はそのまま残す。
    /// 1 語も読めなければ nil
    func englishReading(of source: String) -> String? {
        var readAny = false
        let words = source.split(separator: " ", omittingEmptySubsequences: false).map { word in
            let typed = table.typedKana(of: word)
            guard !word.isEmpty, typed.complete else { return String(word) }
            readAny = true
            return typed.kana
        }
        return readAny ? words.joined(separator: " ") : nil
    }

    /// 句読点。直前の区間が日本語なら日本語の文で使う形にし、英語なら打ったままにする記号と、その形
    static let punctuation: [Character: String] = [",": "、", ".": "。", "?": "？", "!": "！", "~": "〜", "(": "（", ")": "）", ":": "：", "=": "＝"]

    /// 前後の区間によらず決まった記号にする打鍵
    static let symbols: [String: String] = [
        "zh": "←", "zj": "↓", "zk": "↑", "zl": "→",
        "z.": "…", "z/": "・", "z-": "〜", "z[": "『", "z]": "』",
        "/": "・", "[": "「", "]": "」",
    ]
    static let maxSymbolLength = symbols.keys.map(\.count).max()!

    /// 入力を切った句読点・記号の打鍵 key を mark にした区間の後ろの入力の評価のしかた。記号の打鍵の後は文の途中かもしれないもの、
    /// 打ったままの形（組に合わせて半角にした閉じ括弧）の後は英語の後、日本語の記号にした句読点の後は文の頭として評価する
    static func continuation(after key: String, mark: String) -> Continuation {
        if symbols[key] != nil { return .afterJapanese }
        return mark.allSatisfy(\.isASCII) ? .afterEnglish : .start
    }

    /// 句読点は、直前が日本語なら日本語の記号にし、英語なら打ったまま英語の区間に含める。閉じ丸括弧は、組になる開き丸括弧と同じ形にする（punctuationMark）。
    /// 記号の打鍵は、前後によらず記号にする。入力の先頭の句読点は、入力欄の直前（leading）で決める。
    /// 句読点と記号の打鍵を英語の区間に含めないときは、その位置で入力を切り、後ろは continuation(after:mark:) で評価する
    public func segment(_ input: String, leading: Leading = .start) -> [Segment] {
        segment(input, keepsPunctuationTyped: leading.keepsPunctuationTyped, context: leading.japaneseContext, opened: Self.unclosedOpeners(in: leading.text), preceding: Preceding(leading.text.last))
    }

    /// 区切りを決めた部分の採点で比べた区間の候補を返す。句読点の前で英語に続くと分かって採点し直す部分の候補は含めない。診断用
    public func candidates(_ input: String, leading: Leading = .start) -> [ScoredSpan] {
        var spans: [ScoredSpan] = []
        _ = segment(
            input, keepsPunctuationTyped: leading.keepsPunctuationTyped, context: leading.japaneseContext, opened: Self.unclosedOpeners(in: leading.text), preceding: Preceding(leading.text.last)
        ) { spans.append($0) }
        return spans
    }

    /// keepsPunctuationTyped は、入力の先頭の句読点を打ったままにするか。context は、最初の句読点か記号までの部分の最初の日本語区間を評価する形。opened は入力より前の閉じていない開き丸括弧。
    /// preceding は入力の直前で、入力の先頭が数の区切りか（isNumberSeparator）と、長音と読めるか（lengthensOnlyJapanese）を決めるのに使う
    func segment(_ input: String, keepsPunctuationTyped: Bool, context: JapaneseContext, opened: [Character], preceding: Preceding) -> [Segment] {
        segment(input, keepsPunctuationTyped: keepsPunctuationTyped, context: context, opened: opened, preceding: preceding, observe: nil)
    }

    /// observe には、区切りを決めた部分の区間の候補だけを渡す。句読点の前で英語に続くと分かって採点し直す部分の候補は渡さない
    private func segment(
        _ input: String, keepsPunctuationTyped: Bool, context: JapaneseContext, opened: [Character], preceding: Preceding,
        observe: ((ScoredSpan) -> Void)?
    ) -> [Segment] {
        let chars = Array(input)
        var segments: [Segment] = []
        var runStart = 0
        // 今の部分の先頭の句読点を打ったままにするか
        var runKeepsTyped = keepsPunctuationTyped
        var runContext = context
        var opened = opened
        // 今の部分の前が空白か
        var runAfterSpace = false
        var i = 0
        while i < chars.count {
            if chars[i] == " " {
                // 空白も入力を切る。空白より前は、空白を打つ前と同じ打鍵列だけで区切るので、後ろに打った分で変わらない。
                // 空白の後ろの日本語は前の語に続く形（空白の前が数字なら助数詞）で評価する。
                let spaces = chars[i...].prefix { $0 == " " }.count
                let before = segmentRun(String(chars[runStart..<i]), leading: runContext, offset: runStart, preceding: runStart == 0 ? preceding : Preceding(chars[runStart - 1]), spaced: true, observe: observe)
                segments += before
                if !before.isEmpty {
                    runContext = Self.context(after: chars[runStart..<i])
                }
                // 空白の直後の句読点は、空白を飛ばした前の区間（数だけの区間を除く）で決める。数しか無ければ、空白の前で決めた側のまま
                if let last = Self.lastWord(in: before) {
                    runKeepsTyped = Self.keepsPunctuationTyped(after: last)
                }
                segments.append(Self.spaceSegment(String(chars[i..<(i + spaces)]), context: runContext))
                i += spaces
                runStart = i
                runAfterSpace = true
                continue
            }
            let symbol = Self.symbol(at: i, in: chars)
            let key = symbol?.key ?? String(chars[i])
            let end = i + key.count
            defer { i = end }
            guard symbol != nil || Self.punctuation[chars[i]] != nil else { continue }
            if symbol == nil, Self.isNumberSeparator(at: i, in: chars, before: preceding.key) { continue }
            var runSpans: [ScoredSpan] = []
            let collect: ((ScoredSpan) -> Void)? = observe.map { _ in { runSpans.append($0) } }
            let before = segmentRun(String(chars[runStart..<i]), leading: runContext, offset: runStart, preceding: runStart == 0 ? preceding : Preceding(chars[runStart - 1]), spaced: runAfterSpace, observe: collect)
            // 直前の英語の区間か利用者の辞書の語の区間から、句読点をまたいで登録した打鍵どおりに打たれていれば（jpy.dev）、ここで切らずに語として読む
            if symbol == nil, let last = before.last, last.kind != .japanese,
               typesRegisteredKeys(from: i - last.source.count, across: i, in: chars) { continue }
            // 数だけの区間の後ろは、その前の区間で決める（version 2. の 2 の後ろは version の側）
            let previousIsEnglish = Self.lastWord(in: before).map { Self.keepsPunctuationTyped(after: $0) } ?? runKeepsTyped
            // nil なら打ったまま直前の英語の区間に含める。空白の直後は含める英語の語が無いので、打ったままの形の句読点の区間にして入力を切る。
            // 空白の直後の previousIsEnglish は、空白を飛ばした前の区間の表記で決めた runKeepsTyped
            // 利用者の辞書の語の後ろも、含めると打鍵が語と一致しなくなるので、英字で終わる語の後ろは打ったままの形の句読点の区間にして入力を切る
            let afterSpace = runAfterSpace && runStart == i
            // 数だけの区間を飛ばして英語の側に決めたとき（vue3.）も、含めると打鍵が語と一致しなくなるので切る
            let keepsTyped = afterSpace || before.last.map { $0.kind == .word || Self.isNumberSpan($0) } ?? false
            let mark = symbol.map(\.mark)
                ?? Self.punctuationMark(chars[i], opened: &opened, previousIsEnglish: previousIsEnglish)
                ?? (keepsTyped ? String(chars[i]) : nil)
            guard let mark else { continue }
            runSpans.forEach { observe?($0) }
            segments += before
            segments.append(Segment(kind: .punctuation, source: key, reading: mark, output: mark, score: 0, context: .start))
            runStart = end
            let markContinuation = Self.continuation(after: key, mark: mark)
            runKeepsTyped = markContinuation == .afterEnglish
            runContext = markContinuation.japaneseContext
            // 空白の直後の句読点か記号の後ろ（空白で区切った括弧の中の語）も、空白で区切った語として読む
            runAfterSpace = afterSpace
        }
        return segments + segmentRun(String(chars[runStart...]), leading: runContext, offset: runStart, preceding: runStart == 0 ? preceding : Preceding(chars[runStart - 1]), spaced: runAfterSpace, observe: observe)
    }

    /// 打っている途中の表示で、末尾の日本語区間が次の打鍵で読みが変わる単独の n で終わるなら（RomajiTable.readingBeforePendingN）、
    /// その n を外して打ったままの区間にし、残りを n を除いた読みで変換する。n は次の打鍵で な行 にも「ん」にもなるので、
    /// 次の打鍵まで決めない（そうなるとn、にほn）。Enter は見たまま確定するので、「ん」で確定するときは nn と打つ。英語区間は外さない（kotlin）。
    /// 文節に区切るとき（clauses）は外さず、「ん」まで含めて変換する（nihon の候補に 日本）。返す pendingN は n を外したか。
    /// 残りの読みは区間の読みから末尾の「ん」を外したもので、綴りの表から読み直さない（数の区切りの 3-5 は 3ー5 にならない）
    func keepingPendingN(_ segments: [Segment]) -> (segments: [Segment], pendingN: Bool) {
        guard let last = segments.last, last.kind == .japanese, table.readingBeforePendingN(last.source) != nil else { return (segments, false) }
        guard last.reading.last == "ん" else {
            return Unexpected.reached("単独の n で終わる日本語区間の読みが「ん」で終わらない", detail: last.source, continuingWith: (segments, false))
        }
        let kana = String(last.reading.dropLast())
        let pending = englishSegment("n", context: last.context)
        guard !kana.isEmpty else { return (segments.dropLast() + [pending], true) }
        let rest = String(last.source.dropLast())
        let japanese = japaneseSegment(rest, kana: kana, context: last.context, penalty: 0)
        return (segments.dropLast() + [japanese, pending], true)
    }

    /// i から始まる記号の打鍵のうち最も長いもの
    static func symbol(at i: Int, in chars: [Character]) -> (key: String, mark: String)? {
        for length in stride(from: min(maxSymbolLength, chars.count - i), through: 1, by: -1) {
            let key = String(chars[i..<(i + length)])
            if let mark = symbols[key] { return (key, mark) }
        }
        return nil
    }

    /// 句読点と空白を含まない部分を、日本語区間と英語区間の並びに分ける。空でない入力には必ず 1 つ以上の区間を返す。
    /// offset は input が入力全体のどの位置から始まるかで、observe に渡す区間の候補の位置に足す。preceding は input の直前。
    /// spaced は input の前か後ろが空白か。空白で区切って打った語は英語として残したい語なので、input の全体を 1 つの英語区間にする候補に
    /// spacedEnglishBonus を足す
    private func segmentRun(_ input: String, leading: JapaneseContext, offset: Int, preceding: Preceding, spaced: Bool, observe: ((ScoredSpan) -> Void)?) -> [Segment] {
        let chars = Array(input)
        let n = chars.count
        guard n > 0 else { return [] }

        // best[位置][直前の区間の種類] = (評価値, 区間)。英語区間は英語区間に続けない。日本語区間は日本語区間にも続けられる
        struct Cell {
            var score: Double
            var segment: Segment
            var from: Int
            var previousKind: Segment.Kind?
        }
        var best: [[Segment.Kind: Cell]] = Array(repeating: [:], count: n + 1)

        /// pos で終わる、直前の種類が previous の区切りの評価値。pos が 0 なら入力の先頭
        func score(at pos: Int, after previous: Segment.Kind?) -> Double? {
            if pos == 0 { return previous == nil ? 0 : nil }
            guard let previous else { return nil }
            return best[pos][previous]?.score
        }

        func relax(_ end: Int, _ start: Int, _ segment: Segment, after previous: Segment.Kind?) {
            guard let base = score(at: start, after: previous) else { return }
            observe?(ScoredSpan(start: offset + start, end: offset + end, after: previous, segment: segment))
            let total = base + segment.score
            if let current = best[end][segment.kind], current.score >= total { return }
            best[end][segment.kind] = Cell(score: total, segment: segment, from: start, previousKind: previous)
        }

        // 位置ごとの、日本語として最後まで読める終端とかな
        let readingsAt = (0..<n).map { Self.japaneseReadings(table: table, from: $0, in: chars, before: preceding) }
        for start in 0..<n {
            let reachable = start == 0 || !best[start].isEmpty
            guard reachable else { continue }
            // この位置から始まる日本語区間を採れた終端。英語区間を締め出すのは、日本語区間を採れるときだけにする
            var japaneseEnds: Set<Int> = []
            // 英語区間の後は前の語に続く形（数字の後は助数詞）、日本語区間の後は文頭の形で採点する。
            // 日本語区間の後の切れ目は採点のためのもので、区切りが決まったら前の日本語区間とまとめて変換し直す
            let context = start == 0 ? leading : Self.context(after: chars[..<start])
            let predecessors: [(kind: Segment.Kind?, context: JapaneseContext, penalty: Double)] = start == 0
                ? [(nil, leading, Self.japaneseSpanPenalty)]
                : [(.english, context, Self.japaneseSpanPenalty), (.japanese, .start, Self.continuingJapanesePenalty), (.word, context, Self.japaneseSpanPenalty)]
            let readings = readingsAt[start]
            // この位置から綴りの表で最後まで読める終端。英語区間の候補が読める綴りかを引くのに使う
            let readableEnds = Set(readings.map(\.end))
            // 利用者の辞書の語の区間の後は、直前に見えている文字がその語の表示の最後の文字なので、長音をそれで判定し直す。
            // ほかの区間の後は直前の打鍵で判定する（かなの後ろの - は、前のかなとまとめた区間の候補が読む）
            let afterWord = best[start][.word].map { word in
                Self.japaneseReadings(table: table, from: 0, in: Array(chars[start...]), before: Preceding(key: chars[start - 1], shown: word.segment.output.last))
                    .map { (end: start + $0.end, kana: $0.kana) }
            }
            for predecessor in predecessors {
                guard score(at: start, after: predecessor.kind) != nil else { continue }
                for (end, kana) in predecessor.kind == .word ? afterWord ?? readings : readings {
                    let segment = japaneseSegment(String(chars[start..<end]), kana: kana, context: predecessor.context, penalty: predecessor.penalty)
                    japaneseEnds.insert(end)
                    relax(end, start, segment, after: predecessor.kind)
                }
            }
            // 句読点は直前の区間に従い、英語の後なら英語区間に入るので、英語区間を句読点から始めない。入力の先頭は、入力欄の前の英語に続いている
            if start > 0, Self.punctuation[chars[start]] != nil { continue }
            for end in (start + 1)...n {
                let source = String(chars[start..<end])
                if let segment = wordSegment(source, context: context) {
                    for predecessor in predecessors { relax(end, start, segment, after: predecessor.kind) }
                    continue
                }
                if prefersJapanese(source, readable: readableEnds.contains(end)), japaneseEnds.contains(end) { continue }
                var english = englishSegment(source, context: context)
                if spaced, start == 0, end == n { english.score += Self.spacedEnglishBonus }
                for previous in start == 0 ? [nil] : [Segment.Kind.japanese, .word] {
                    relax(end, start, english, after: previous)
                }
            }
        }

        var segments: [Segment] = []
        var pos = n
        var kind = best[n].max { $0.value.score < $1.value.score }?.key
        while pos > 0, let k = kind, let cell = best[pos][k] {
            segments.append(cell.segment)
            pos = cell.from
            kind = cell.previousKind
        }
        // どの区間も、日本語として採れなければ英語として採れるので、空でない入力には必ず区切りがある
        guard pos == 0, !segments.isEmpty else {
            return Unexpected.reached("区切りが見つからない", detail: input, continuingWith: [englishSegment(input, context: leading)])
        }
        return mergeJapanese(segments.reversed())
    }

    /// source の全体を 1 区間として、日本語区間と英語区間のうち評価値の高い方にする。区切りの選択と同じく、
    /// 利用者の辞書で日本語として扱う読めない打鍵ならその語の区間、読めない箇所を含めば英語、日本語として採れて英語にしない綴りなら日本語にする。
    /// preceding は source の直前
    func singleSpan(_ source: String, context: JapaneseContext, preceding: Preceding) -> Segment {
        if let word = wordSegment(source, context: context) { return word }
        let english = englishSegment(source, context: context)
        guard let kana = Self.japaneseReading(table: table, of: source, before: preceding) else { return english }
        let japanese = japaneseSegment(source, kana: kana, context: context, penalty: Self.japaneseSpanPenalty)
        return prefersJapanese(source, readable: true) || japanese.score >= english.score ? japanese : english
    }

    /// 続く空白の区間。採点で比べないので点を持たない英語の区間にする。context は空白の後ろの日本語を評価する文脈
    static func spaceSegment(_ source: String, context: JapaneseContext) -> Segment {
        if source.isEmpty || !source.allSatisfy({ $0 == " " }) {
            Unexpected.reached("空白の区間が空白以外を含む", detail: source, continuingWith: ())
        }
        return Segment(kind: .english, source: source, reading: source, output: source, score: 0, context: context)
    }

    /// source の全体を、採点で比べずに kind の 1 区間にする。日本語にするのに綴りの表で読み切れなければ nil。preceding は source の直前
    func span(_ source: String, as kind: Segment.Kind, context: JapaneseContext, preceding: Preceding) -> Segment? {
        switch kind {
        case .english:
            return englishSegment(source, context: context)
        case .japanese:
            guard let kana = Self.japaneseReading(table: table, of: source, before: preceding) else { return nil }
            return japaneseSegment(source, kana: kana, context: context, penalty: Self.japaneseSpanPenalty)
        case .punctuation, .word:
            return Unexpected.reached("指定した言語で作る区間は日本語か英語だけ", continuingWith: nil)
        }
    }

    /// 1 つのかなになる綴り（ga to de no）、読める 2 文字以下の綴り（ie）、読めて英語の語でない綴り（utte deno matte）は、
    /// 日本語として採れるなら英語にしない。数だけの綴り（1500 3.14）も同じく英語にしない。数字と英字が混ざる綴り（3i 3a i18n）は、
    /// どれにも当たらず、日本語の読みと英語の綴りのもっともらしさを点で比べる。利用者の辞書で英語として扱う打鍵は、どれにも当たらない
    func prefersJapanese(_ source: String, readable: Bool) -> Bool {
        guard typedWords[source] == nil else { return false }
        guard !Self.isNumber(source) else { return readable }
        guard !source.contains(where: Self.isDigit) else { return false }
        return table.isSingleKana(source) || (readable && (source.count <= Self.maxJapaneseFirstLength || !english.isWord(source)))
    }

    private func japaneseSegment(_ source: String, kana: String, context: JapaneseContext, penalty: Double) -> Segment {
        let reading = japaneseConverter.convert(kana: kana, context: context)
        let score = reading.value - penalty
        return Segment(kind: .japanese, source: source, reading: kana, output: reading.text, score: score, context: reading.context)
    }

    /// 利用者の辞書で日本語として扱う、かなに読めない打鍵にちょうど一致すれば、最初に登録した語の区間
    private func wordSegment(_ source: String, context: JapaneseContext) -> Segment? {
        typedJapaneseWords[source].map { Segment(kind: .word, source: source, reading: source, output: $0[0], score: Self.registeredScore, context: context) }
    }

    private func englishSegment(_ source: String, context: JapaneseContext) -> Segment {
        let singleLetter = source.filter(\.isLetter).count == 1 ? Self.singleLetterEnglishPenalty : 0
        let spelled = spellingScore(source, context: context) - Self.englishSpanPenalty - singleLetter
        let score = typedWords[source] == nil ? spelled : max(spelled, Self.registeredScore)
        return Segment(kind: .english, source: source, reading: source, output: englishOutput(source), score: score, context: context)
    }

    /// 英語区間の綴りの点。数（numberLength）は英単語の綴りではないので、日本語区間と同じく採点の変換で数として読んだ点にし、
    /// 数字で切った残りの綴りをそれぞれ英語の綴りとして測る。区間の頭の数は区間の文脈で、英字の後の数は語の後として読む
    private func spellingScore(_ source: String, context: JapaneseContext) -> Double {
        var score = 0.0
        var rest = Substring(source)
        while !rest.isEmpty {
            let number = rest.prefix(Self.numberLength(rest))
            if !number.isEmpty {
                let at: JapaneseContext = rest.startIndex == source.startIndex ? context : .afterWord
                score += japaneseConverter.convert(kana: String(number), context: at).value
                rest = rest.dropFirst(number.count)
                continue
            }
            let spelling = rest.prefix { !Self.isDigit($0) }
            score += Self.englishWeight * english.logProbability(spelling)
            rest = rest.dropFirst(spelling.count)
        }
        return score
    }

    /// chars の start から、位置 i をまたぐ長さの利用者の辞書の打鍵（英語の語と、かなに読めない日本語の語）がそのまま打たれているか
    private func typesRegisteredKeys(from start: Int, across i: Int, in chars: [Character]) -> Bool {
        [typedWords.keys, typedJapaneseWords.keys].joined().contains { keys in
            start + keys.count > i && start + keys.count <= chars.count && chars[start..<(start + keys.count)].elementsEqual(keys)
        }
    }

    /// 英語区間の表記。空白で区切った綴りのうち、利用者の辞書で英語として扱う打鍵と一致するものを、最初に登録した表記にする
    private func englishOutput(_ source: String) -> String {
        source.split(separator: " ", omittingEmptySubsequences: false).map { registered(String($0)) }.joined(separator: " ")
    }

    /// 綴りを句読点で区切り、頭から、句読点をまたいで最も長く一致する登録した打鍵（node.js、jpy.dev）ごとに引く。
    /// 英語の後の句読点は英語区間に入るので（github, や github,gitlab や jpy.dev,）
    private func registered(_ spelling: String) -> String {
        var tokens: [String] = []
        for c in spelling {
            if Self.punctuation[c] != nil || tokens.last.map({ Self.punctuation[$0.last!] != nil }) ?? true {
                tokens.append(String(c))
            } else {
                tokens[tokens.count - 1].append(c)
            }
        }
        var shown = ""
        var start = 0
        while start < tokens.count {
            let end = (start..<tokens.count).reversed().first { typedWords[tokens[start...$0].joined()] != nil }
            guard let end else {
                shown += tokens[start]
                start += 1
                continue
            }
            shown += typedWords[tokens[start...end].joined()]![0]
            start = end + 1
        }
        return shown
    }

    /// 隣り合う日本語区間を 1 つにまとめ、まとめた読みを最初の区間の文脈で変換し直す。
    /// まとめた区間の点は、区切りを決めた区間ごとの点の和にする
    private func mergeJapanese(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for segment in segments {
            guard segment.kind == .japanese, let last = merged.last, last.kind == .japanese else {
                merged.append(segment)
                continue
            }
            let reading = last.reading + segment.reading
            let whole = japaneseConverter.convert(kana: reading, context: last.context)
            merged[merged.count - 1] = Segment(
                kind: .japanese,
                source: last.source + segment.source,
                reading: reading,
                output: whole.text,
                score: last.score + segment.score,
                context: whole.context
            )
        }
        return merged
    }
}
