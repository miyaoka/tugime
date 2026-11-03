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
    /// 英語の綴りの評価値を、日本語の変換の評価値と同じ尺度に揃える倍率
    static let englishWeight = 1.4
    /// 日本語の区間を 1 つ増やすごとに引く値
    static let japaneseSpanPenalty = 3.0
    /// 日本語区間に続く日本語区間で引く値
    static let continuingJapanesePenalty = 2.0
    /// 英語の区間を 1 つ増やすごとに引く値。負なので、英語の区間は増やすほど点が上がる
    static let englishSpanPenalty = -2.0
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
        /// 未確定の文字列の最初の表示の変換は左の文脈をすべてモデルに通すので、長くするほど打ち始めの打鍵が遅くなる
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

        /// 入力の最初の日本語区間の評価のしかた。前の文字列が数字で終わるなら、未確定の文字列の中の数字の後と同じく、その数字に続く形にする。
        /// 確定してから続きを打っても、まとめて打ったときと同じ評価になる
        var japaneseContext: JapaneseContext {
            let afterText = Segmenter.context(after: text)
            if case .afterNumber = afterText { return afterText }
            return continuation.japaneseContext
        }
    }

    /// 入力が前の文字列のどこに続くか
    enum Continuation: Equatable {
        /// 文頭。前に何も無いか、空白・改行・文末の記号の後
        case start
        /// 日本語の文の途中
        case afterJapanese
        /// 英字・記号など ASCII の後
        case afterEnglish

        /// 前の文字列の最後の文字から決める。無い、空白・改行、文末の記号の後なら文頭、それ以外の ASCII の後なら英語の後、残りは日本語の後。
        /// 数（numberLength）で終わるなら、未確定の文字列の中と同じく、数はその前の文字の側に付く。前が ASCII の英字や記号なら英語の後、それ以外は日本語の後
        init(after text: String) {
            let number = Segmenter.numberLength(text.reversed())
            guard number > 0 else {
                self.init(last: text.last)
                return
            }
            let before = text.dropLast(number).last
            self = before.map { $0.isASCII && !$0.isWhitespace } == true ? .afterEnglish : .afterJapanese
        }

        private init(last: Character?) {
            guard let last, !last.isWhitespace, !last.unicodeScalars.contains(where: \.properties.isSentenceTerminal) else {
                self = .start
                return
            }
            self = last.isASCII ? .afterEnglish : .afterJapanese
        }

        /// 最初の日本語区間の評価のしかた
        var japaneseContext: JapaneseContext { self == .start ? .start : .afterCaret }
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

    /// chars[i] が数字の直後の - か。数字の後ろでは長音ではないので、綴りの表で ー と読まない。数字にはさまれていれば数の一部、
    /// 後ろに数字がまだ無ければ（打っている途中の 3-）打ったまま
    static func isNumberDash(at i: Int, in chars: [Character], before: Character?) -> Bool {
        chars[i] == "-" && (i > 0 ? chars[i - 1] : before).map(isDigit) == true
    }

    /// start から日本語として読み切れる終端ごとのかな。綴りの表で読み、数字にはさまれた numberSeparators は打ったまま読みに入れる（3.14 は 3.14）。
    /// 数字の直後の - を ー と読む読みは除く
    static func japaneseReadings(table: RomajiTable, from start: Int, in chars: [Character], before: Character?) -> [(end: Int, kana: String)] {
        var found: [Int: String] = [:]
        var pending: [(position: Int, kana: String)] = [(start, "")]
        while let (position, prefix) = pending.popLast() {
            let limit = (position..<chars.count).first { isNumberDash(at: $0, in: chars, before: before) } ?? chars.count
            for reading in table.readings(from: position, in: chars) where reading.end <= limit && found[reading.end] == nil {
                let kana = prefix + reading.kana
                found[reading.end] = kana
                if reading.end < chars.count, isNumberSeparator(at: reading.end, in: chars, before: before) {
                    pending.append((reading.end + 1, kana + String(chars[reading.end])))
                }
            }
        }
        return found.sorted { $0.key < $1.key }.map { (end: $0.key, kana: $0.value) }
    }

    /// 綴り全体を日本語として読み切れればかな
    static func japaneseReading(table: RomajiTable, of text: some StringProtocol, before: Character?) -> String? {
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
    }

    /// 打っている途中に見せる文字列。日本語区間は変換し、英語区間は打ったまま。末尾の単独の n は打ったまま見せる（keepingPendingN）。
    /// 前の文字列は、区切りの評価と、表示の変換の左の文脈に使う
    public func liveDisplay(_ input: String, leading: Leading = .start) -> LiveDisplay {
        let (segments, pendingN) = keepingPendingN(segment(input, leading: leading))
        var differs = false
        let shown = displays(of: segments.map(ShownSpan.init), left: leading.text, startsAtHead: true, endsWithPendingN: pendingN)
        let text = zip(segments, shown).map { segment, display in
            guard let display else { return segment.output }
            if !display.matchesReading { differs = true }
            return display.text
        }.joined()
        return LiveDisplay(text: text, differsFromInput: differs)
    }

    /// 表示する 1 区間。日本語区間は表示の変換で表記を決め、それ以外は決まった文字列を表示する。
    /// 句読点と記号の打鍵（mark）は、後ろが文の頭か（startsSentence）を持つ。組に合わせて半角にした閉じ括弧の後ろは英語の後で、文の頭ではない
    enum ShownSpan {
        case japanese(kana: String, context: JapaneseContext)
        case fixed(String)
        case mark(String, startsSentence: Bool)

        init(_ segment: Segment) {
            switch segment.kind {
            case .japanese: self = .japanese(kana: segment.reading, context: segment.context)
            case .punctuation: self = .mark(segment.output, startsSentence: Segmenter.continuation(after: segment.source, mark: segment.output) != .afterEnglish)
            case .english, .word: self = .fixed(segment.output)
            }
        }
    }

    /// 区間を前から順に表示の変換にする。日本語区間は、left にそれより前の区間の表示をつないだものを左の文脈にする。
    /// 返す配列は spans と同じ順で、日本語区間の要素だけが表示の変換を持つ。
    /// 末尾の区間（endsWithPendingN なら、最後の打ったままの n の手前）が文の頭（入力の最初の区間か、日本語の記号にした句読点・記号の直後）の
    /// 1 かなだけなら、続けて打つ語の先頭なので、変換せずにかなのまま見せる（ki は 気 ではなく き、kon は こn）。
    /// startsAtHead は spans の最初が入力の最初の区間か（文節の伸縮で後ろだけを渡すときは偽）
    func displays(of spans: [ShownSpan], left: String, startsAtHead: Bool, endsWithPendingN: Bool) -> [JapaneseDisplay?] {
        var shown = left
        let lastSpan = spans.count - (endsWithPendingN ? 2 : 1)
        return spans.enumerated().map { index, span in
            switch span {
            case .fixed(let text), .mark(let text, _):
                shown += text
                return nil
            case .japanese(let kana, let context):
                let atHead = index == 0 ? startsAtHead : { if case .mark(_, true) = spans[index - 1] { true } else { false } }()
                if index == lastSpan, atHead, kana.count == 1 {
                    shown += kana
                    return JapaneseDisplay(text: kana, clauses: [JapaneseClause(reading: kana, text: kana)])
                }
                let display = japaneseConverter.display(kana: kana, context: context, left: shown)
                shown += display.text
                return display
            }
        }
    }

    /// この長さ以下の読める綴りは、英語の語であっても日本語として読む
    static let maxJapaneseFirstLength = 2

    /// 長音だけの区間は日本語として成り立たない（binge-watch の - など）
    static func canBeJapanese(_ kana: String) -> Bool {
        !kana.allSatisfy { $0 == "ー" }
    }

    /// 英語区間を、空白で区切った語ごとに綴りの表で読んだもの。読めない語は打ったまま、空白はそのまま残す。1 語も読めなければ nil
    func englishReading(of source: String) -> String? {
        var readAny = false
        let words = source.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard let kana = table.reading(of: word) else { return String(word) }
            readAny = true
            return kana
        }
        return readAny ? words.joined(separator: " ") : nil
    }

    /// 句読点。直前の区間が日本語なら日本語の文で使う形にし、英語なら打ったままにする記号と、その形
    static let punctuation: [Character: String] = [",": "、", ".": "。", "?": "？", "!": "！", "~": "〜", "(": "（", ")": "）", ":": "：", "=": "＝"]

    /// 前後の区間によらず決まった記号にする打鍵。日本語モードでは打ったまま出さない
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
        segment(input, after: leading.continuation, context: leading.japaneseContext, opened: Self.unclosedOpeners(in: leading.text), preceding: leading.text.last)
    }

    /// 区切りを決めた部分の採点で比べた区間の候補を返す。句読点の前で英語に続くと分かって採点し直す部分の候補は含めない。診断用
    public func candidates(_ input: String, leading: Leading = .start) -> [ScoredSpan] {
        var spans: [ScoredSpan] = []
        _ = segment(
            input, after: leading.continuation, context: leading.japaneseContext, opened: Self.unclosedOpeners(in: leading.text), preceding: leading.text.last
        ) { spans.append($0) }
        return spans
    }

    /// context は、最初の句読点か記号までの部分の最初の日本語区間を評価する形。opened は入力より前の閉じていない開き丸括弧。
    /// preceding は入力の直前の文字で、入力の先頭が数の区切りか（isNumberSeparator、isNumberDash）を決めるのに使う
    func segment(_ input: String, after continuation: Continuation, context: JapaneseContext, opened: [Character], preceding: Character?) -> [Segment] {
        segment(input, after: continuation, context: context, opened: opened, preceding: preceding, observe: nil)
    }

    /// observe には、区切りを決めた部分の区間の候補だけを渡す。句読点の前で英語に続くと分かって採点し直す部分の候補は渡さない
    private func segment(
        _ input: String, after continuation: Continuation, context: JapaneseContext, opened: [Character], preceding: Character?,
        observe: ((ScoredSpan) -> Void)?
    ) -> [Segment] {
        let chars = Array(input)
        var segments: [Segment] = []
        var runStart = 0
        var runContinuation = continuation
        var runContext = context
        var opened = opened
        var i = 0
        while i < chars.count {
            let symbol = Self.symbol(at: i, in: chars)
            let key = symbol?.key ?? String(chars[i])
            let end = i + key.count
            defer { i = end }
            guard symbol != nil || Self.punctuation[chars[i]] != nil else { continue }
            if symbol == nil, Self.isNumberSeparator(at: i, in: chars, before: preceding) { continue }
            var runSpans: [ScoredSpan] = []
            let collect: ((ScoredSpan) -> Void)? = observe.map { _ in { runSpans.append($0) } }
            let before = segmentRun(String(chars[runStart..<i]), leading: runContext, offset: runStart, preceding: runStart == 0 ? preceding : chars[runStart - 1], observe: collect)
            let previousIsEnglish = before.last.map { $0.kind == .english } ?? (runContinuation == .afterEnglish)
            // nil なら打ったまま直前の英語の区間に含める
            let mark = symbol.map(\.mark) ?? Self.punctuationMark(chars[i], opened: &opened, previousIsEnglish: previousIsEnglish)
            guard let mark else { continue }
            runSpans.forEach { observe?($0) }
            segments += before
            segments.append(Segment(kind: .punctuation, source: key, reading: mark, output: mark, score: 0, context: .start))
            runStart = end
            runContinuation = Self.continuation(after: key, mark: mark)
            runContext = runContinuation.japaneseContext
        }
        return segments + segmentRun(String(chars[runStart...]), leading: runContext, offset: runStart, preceding: runStart == 0 ? preceding : chars[runStart - 1], observe: observe)
    }

    /// 打っている途中の表示で、末尾の日本語区間が次の打鍵で読みが変わる単独の n で終わるなら（RomajiTable.readingBeforePendingN）、
    /// その n を外して打ったままの区間にし、残りを n を除いた読みで変換する。n は次の打鍵で な行 にも「ん」にもなるので、
    /// 次の打鍵まで決めない（そうなるとn、にほn）。Enter は見たまま確定するので、「ん」で確定するときは nn と打つ。英語区間は外さない（kotlin）。
    /// 文節に区切るとき（clauses）は外さず、「ん」まで含めて変換する（nihon の候補に 日本）。返す pendingN は n を外したか
    private func keepingPendingN(_ segments: [Segment]) -> (segments: [Segment], pendingN: Bool) {
        guard let last = segments.last, last.kind == .japanese, let kana = table.readingBeforePendingN(last.source) else { return (segments, false) }
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

    /// 句読点を含まない部分を、日本語区間と英語区間の並びに分ける。空でない入力には必ず 1 つ以上の区間を返す。
    /// offset は input が入力全体のどの位置から始まるかで、observe に渡す区間の候補の位置に足す。preceding は input の直前の文字
    private func segmentRun(_ input: String, leading: JapaneseContext, offset: Int, preceding: Character?, observe: ((ScoredSpan) -> Void)?) -> [Segment] {
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
            for (end, kana) in readings where Self.canBeJapanese(kana) {
                for predecessor in predecessors {
                    guard score(at: start, after: predecessor.kind) != nil else { continue }
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
                for previous in start == 0 ? [nil] : [Segment.Kind.japanese, .word] {
                    relax(end, start, englishSegment(source, context: context), after: previous)
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
        precondition(pos == 0 && !segments.isEmpty, "区切りが見つからない: \(input)")
        return mergeJapanese(segments.reversed())
    }

    /// source の全体を 1 区間として、日本語区間と英語区間のうち評価値の高い方にする。区切りの選択と同じく、
    /// 利用者の辞書で日本語として扱う読めない打鍵ならその語の区間、読めない箇所を含めば英語、日本語として採れて英語にしない綴りなら日本語にする。
    /// preceding は source の直前の文字
    func singleSpan(_ source: String, context: JapaneseContext, preceding: Character?) -> Segment {
        if let word = wordSegment(source, context: context) { return word }
        let english = englishSegment(source, context: context)
        guard let kana = Self.japaneseReading(table: table, of: source, before: preceding), Self.canBeJapanese(kana) else { return english }
        let japanese = japaneseSegment(source, kana: kana, context: context, penalty: Self.japaneseSpanPenalty)
        return prefersJapanese(source, readable: true) || japanese.score >= english.score ? japanese : english
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

    /// 英語区間の表記。空白で区切った綴りのうち、利用者の辞書で英語として扱う打鍵と一致するものを、最初に登録した表記にする
    private func englishOutput(_ source: String) -> String {
        source.split(separator: " ", omittingEmptySubsequences: false).map { registered(String($0)) }.joined(separator: " ")
    }

    /// 綴りをそのまま引き（node.js）、無ければ句読点で区切った綴りごとに引く。英語の後の句読点は英語区間に入るので（github, や github,gitlab）
    private func registered(_ spelling: String) -> String {
        if let word = typedWords[spelling]?.first { return word }
        var shown = ""
        var run = ""
        for c in spelling {
            guard Self.punctuation[c] != nil else {
                run.append(c)
                continue
            }
            shown += typedWords[run]?.first ?? run
            shown.append(c)
            run = ""
        }
        return shown + (typedWords[run]?.first ?? run)
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
