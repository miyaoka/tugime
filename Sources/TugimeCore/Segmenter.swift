import Foundation

public struct Segment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        /// 日本語の記号にした句読点（, . ? ! ~）と記号の打鍵（zh [ / など）
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
    let table: RomajiTable
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
    /// 英字が 1 文字だけの英語の区間で、さらに引く値。入力の末尾の区間には引かない。
    /// 末尾の 1 文字は打ちかけの綴り（ことばh の h）で、引くと前のかなを巻き込んだ英語の区間（こと + bah）が勝ち、出ていた変換が崩れる
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
        var continuation: Continuation { Continuation(after: text.last) }

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
        /// 英字・数字・記号など ASCII の後
        case afterEnglish

        /// 前の文字列の最後の文字から決める。無い、空白・改行、文末の記号の後なら文頭、それ以外の ASCII の後なら英語の後、残りは日本語の後
        init(after last: Character?) {
            guard let last, !last.isWhitespace, !last.unicodeScalars.contains(where: \.properties.isSentenceTerminal) else {
                self = .start
                return
            }
            self = last.isASCII ? .afterEnglish : .afterJapanese
        }

        /// 最初の日本語区間の評価のしかた
        var japaneseContext: JapaneseContext { self == .start ? .start : .afterCaret }
    }

    /// 英語区間に続く日本語区間の評価のしかた。英語区間が数字で終わるなら、その数字に続く形（1500 円、3 回）にする
    static func context(after text: some Collection<Character>) -> JapaneseContext {
        let digits = String(text.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        return digits.isEmpty ? .afterWord : .afterNumber(digits)
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

    /// 打っている途中に見せる文字列。日本語区間は変換し、英語区間は打ったまま。
    /// 前の文字列は、区切りの評価と、表示の変換の左の文脈に使う
    public func liveDisplay(_ input: String, leading: Leading = .start) -> LiveDisplay {
        let segments = segment(input, leading: leading)
        var differs = false
        let text = zip(segments, displays(of: segments.map(ShownSpan.init), left: leading.text)).map { segment, display in
            guard let display else { return segment.output }
            if !display.matchesReading { differs = true }
            return display.text
        }.joined()
        return LiveDisplay(text: text, differsFromInput: differs)
    }

    /// 表示する 1 区間。日本語区間は表示の変換で表記を決め、それ以外は決まった文字列を表示する
    enum ShownSpan {
        case japanese(kana: String, context: JapaneseContext)
        case fixed(String)

        init(_ segment: Segment) {
            self = segment.kind == .japanese ? .japanese(kana: segment.reading, context: segment.context) : .fixed(segment.output)
        }
    }

    /// 区間を前から順に表示の変換にする。日本語区間は、left にそれより前の区間の表示をつないだものを左の文脈にする。
    /// 返す配列は spans と同じ順で、日本語区間の要素だけが表示の変換を持つ。
    /// 日本語区間は採点の変換があるときだけ選ばれ、表示の変換は採点の変換があれば必ず返すので、日本語区間の表示の変換は必ずある
    func displays(of spans: [ShownSpan], left: String) -> [JapaneseDisplay?] {
        var shown = left
        return spans.map { span in
            switch span {
            case .fixed(let text):
                shown += text
                return nil
            case .japanese(let kana, let context):
                guard let display = japaneseConverter.display(kana: kana, context: context, left: shown) else {
                    preconditionFailure("日本語区間の表示の変換が無い: \(kana)")
                }
                shown += display.text
                return display
            }
        }
    }

    /// この長さ以下の読める綴りは、英語の語であっても日本語として読む
    static let maxJapaneseFirstLength = 2
    /// 区切りの採点で変換する日本語区間の読みの長さの上限。長い日本語は短い日本語区間の連なりとして採点し、
    /// 区切りが決まってからまとめて変換し直す
    static let maxScoredKana = 8

    /// 日本語区間の候補として採点する読み
    static func isScoredJapanese(_ kana: String) -> Bool {
        kana.count <= maxScoredKana && canBeJapanese(kana)
    }

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

    /// 前の語の後ろに付く記号と、日本語の文で使う形
    static let punctuation: [Character: String] = [",": "、", ".": "。", "?": "？", "!": "！", "~": "〜"]

    /// 前後の区間によらず決まった記号にする打鍵。日本語モードでは打ったまま出さない
    static let symbols: [String: String] = [
        "zh": "←", "zj": "↓", "zk": "↑", "zl": "→",
        "z.": "…", "z/": "・", "z-": "〜", "z[": "『", "z]": "』",
        "/": "・", "[": "「", "]": "」",
    ]
    static let maxSymbolLength = symbols.keys.map(\.count).max()!

    /// 日本語の記号にした句読点・記号の打鍵 key の後ろの入力の評価のしかた。句読点の後は文頭、記号の打鍵の後は文の途中かもしれないものとする
    static func continuation(after key: String) -> Continuation {
        symbols[key] == nil ? .start : .afterJapanese
    }

    /// 句読点は前の語の後ろに付くので、直前が日本語なら日本語の記号にし、英語なら打ったまま英語の区間に含める。
    /// 記号の打鍵は、前後によらず記号にする。入力の先頭の句読点は、入力欄の直前（leading）で決める。
    /// 日本語の記号の位置で入力を切る。句読点の後は文頭として、記号の打鍵の後は文の途中かもしれないものとして次の部分を評価する
    public func segment(_ input: String, leading: Leading = .start) -> [Segment] {
        segment(input, after: leading.continuation, context: leading.japaneseContext)
    }

    /// 区切りを決めた部分の採点で比べた区間の候補を返す。句読点の前で英語に続くと分かって採点し直す部分の候補は含めない。診断用
    public func candidates(_ input: String, leading: Leading = .start) -> [ScoredSpan] {
        var spans: [ScoredSpan] = []
        _ = segment(input, after: leading.continuation, context: leading.japaneseContext) { spans.append($0) }
        return spans
    }

    /// context は、最初の句読点か記号までの部分の最初の日本語区間を評価する形
    func segment(_ input: String, after continuation: Continuation, context: JapaneseContext) -> [Segment] {
        segment(input, after: continuation, context: context, observe: nil)
    }

    /// observe には、区切りを決めた部分の区間の候補だけを渡す。句読点の前で英語に続くと分かって採点し直す部分の候補は渡さない
    private func segment(_ input: String, after continuation: Continuation, context: JapaneseContext, observe: ((ScoredSpan) -> Void)?) -> [Segment] {
        let chars = Array(input)
        var segments: [Segment] = []
        var runStart = 0
        var runContinuation = continuation
        var runContext = context
        var i = 0
        while i < chars.count {
            let symbol = Self.symbol(at: i, in: chars)
            let key = symbol?.key ?? String(chars[i])
            let mark = symbol?.mark ?? Self.punctuation[chars[i]]
            let end = i + key.count
            defer { i = end }
            guard let mark else { continue }
            var runSpans: [ScoredSpan] = []
            let collect: ((ScoredSpan) -> Void)? = observe.map { _ in { runSpans.append($0) } }
            let before = segmentRun(String(chars[runStart..<i]), leading: runContext, offset: runStart, endsInput: false, observe: collect)
            let previousIsEnglish = before.last.map { $0.kind == .english } ?? (runContinuation == .afterEnglish)
            if symbol == nil, previousIsEnglish { continue }
            runSpans.forEach { observe?($0) }
            segments += before
            segments.append(Segment(kind: .punctuation, source: key, reading: mark, output: mark, score: 0, context: .start))
            runStart = end
            runContinuation = Self.continuation(after: key)
            runContext = runContinuation.japaneseContext
        }
        return segments + segmentRun(String(chars[runStart...]), leading: runContext, offset: runStart, endsInput: true, observe: observe)
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
    /// offset は input が入力全体のどの位置から始まるかで、observe に渡す区間の候補の位置に足す。endsInput は input が入力の末尾までか
    private func segmentRun(_ input: String, leading: JapaneseContext, offset: Int, endsInput: Bool, observe: ((ScoredSpan) -> Void)?) -> [Segment] {
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

        // 位置ごとの、綴りの表で最後まで読める終端とかな
        let readingsAt = (0..<n).map { table.readings(from: $0, in: chars) }
        // 位置ごとの、日本語区間に続く日本語区間の連なりで届く終端。採点する読みの長さを超える区間も、
        // 日本語区間の連なりとして採れるなら日本語として採れるものとして英語区間を締め出す
        var chained: [Set<Int>] = Array(repeating: [], count: n + 1)
        for start in stride(from: n - 1, through: 1, by: -1) {
            for (end, kana) in readingsAt[start] where Self.isScoredJapanese(kana) {
                guard japaneseConverter.convert(kana: kana, context: .start) != nil else { continue }
                chained[start].insert(end)
                chained[start].formUnion(chained[end])
            }
        }

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
            for (end, kana) in readings where Self.isScoredJapanese(kana) {
                for predecessor in predecessors {
                    guard score(at: start, after: predecessor.kind) != nil,
                          let segment = japaneseSegment(String(chars[start..<end]), kana: kana, context: predecessor.context, penalty: predecessor.penalty)
                    else { continue }
                    japaneseEnds.insert(end)
                    relax(end, start, segment, after: predecessor.kind)
                }
            }
            let japaneseReach = japaneseEnds.reduce(into: japaneseEnds) { $0.formUnion(chained[$1]) }
            // 句読点は前の語の後ろに付くので、英語区間を句読点から始めない。入力の先頭は、入力欄の前の英語に付いている
            if start > 0, Self.punctuation[chars[start]] != nil { continue }
            for end in (start + 1)...n {
                let source = String(chars[start..<end])
                if let segment = wordSegment(source, context: context) {
                    for predecessor in predecessors { relax(end, start, segment, after: predecessor.kind) }
                    continue
                }
                if prefersJapanese(source, readable: readableEnds.contains(end)), japaneseReach.contains(end) { continue }
                for previous in start == 0 ? [nil] : [Segment.Kind.japanese, .word] {
                    relax(end, start, englishSegment(source, context: context, atInputEnd: endsInput && end == n), after: previous)
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
    /// 利用者の辞書で日本語として扱う読めない打鍵ならその語の区間、読めない箇所を含めば英語、日本語として採れて英語にしない綴りなら日本語にする
    func singleSpan(_ source: String, context: JapaneseContext) -> Segment {
        if let word = wordSegment(source, context: context) { return word }
        let english = englishSegment(source, context: context, atInputEnd: false)
        guard let kana = table.reading(of: source), Self.canBeJapanese(kana),
              let japanese = japaneseSegment(source, kana: kana, context: context, penalty: Self.japaneseSpanPenalty)
        else { return english }
        return prefersJapanese(source, readable: true) || japanese.score >= english.score ? japanese : english
    }

    /// 1 つのかなになる綴り（ga to de no）、読める 2 文字以下の綴り（ie）、読めて英語の語でない綴り（utte deno matte）は、
    /// 日本語として採れるなら英語にしない。利用者の辞書で英語として扱う打鍵は、どれにも当たらない
    func prefersJapanese(_ source: String, readable: Bool) -> Bool {
        guard typedWords[source] == nil else { return false }
        return table.isSingleKana(source) || (readable && (source.count <= Self.maxJapaneseFirstLength || !english.isWord(source)))
    }

    private func japaneseSegment(_ source: String, kana: String, context: JapaneseContext, penalty: Double) -> Segment? {
        guard let reading = japaneseConverter.convert(kana: kana, context: context) else { return nil }
        let score = reading.value - penalty
        return Segment(kind: .japanese, source: source, reading: kana, output: reading.text, score: score, context: reading.context)
    }

    /// 利用者の辞書で日本語として扱う、かなに読めない打鍵にちょうど一致すれば、最初に登録した語の区間
    private func wordSegment(_ source: String, context: JapaneseContext) -> Segment? {
        typedJapaneseWords[source].map { Segment(kind: .word, source: source, reading: source, output: $0[0], score: Self.registeredScore, context: context) }
    }

    private func englishSegment(_ source: String, context: JapaneseContext, atInputEnd: Bool) -> Segment {
        let singleLetter = !atInputEnd && source.filter(\.isLetter).count == 1 ? Self.singleLetterEnglishPenalty : 0
        let spelled = Self.englishWeight * english.logProbability(source) - Self.englishSpanPenalty - singleLetter
        let score = typedWords[source] == nil ? spelled : max(spelled, Self.registeredScore)
        return Segment(kind: .english, source: source, reading: source, output: englishOutput(source), score: score, context: context)
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
    /// まとめた読みを変換できなければまとめない。各区間は採点のときに自分の文脈で変換できているので、文節に分けても同じ変換になる。
    /// まとめた区間の点は、区切りを決めた区間ごとの点の和にする
    private func mergeJapanese(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for segment in segments {
            guard segment.kind == .japanese, let last = merged.last, last.kind == .japanese else {
                merged.append(segment)
                continue
            }
            let reading = last.reading + segment.reading
            guard let whole = japaneseConverter.convert(kana: reading, context: last.context) else {
                merged.append(segment)
                continue
            }
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
