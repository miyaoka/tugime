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
    /// 利用者の辞書で日本語として扱う、かなに読める打鍵。語はその読みでかな漢字変換に入れる
    var typedReadableJapanese: Set<String> = []
    /// 英語の綴りの評価値を、日本語の変換の評価値と同じ尺度に揃える倍率
    static let englishWeight = 1.4
    /// 日本語の区間を 1 つ増やすごとに引く値
    static let japaneseSpanPenalty = 3.0
    /// 日本語区間に続く日本語区間で引く値
    static let continuingJapanesePenalty = 2.0
    /// 英語の区間を 1 つ増やすごとに引く値。負なので、英語の区間は増やすほど点が上がる
    static let englishSpanPenalty = -2.0
    /// 英字が 1 文字だけの英語の区間で、さらに引く値。入力の末尾にあって、かなに読めないその 1 文字で終わる区間には引かない。
    /// その 1 文字は打ちかけの綴り（ことばh の h）で、引くと前のかなを巻き込んだ英語の区間（こと + bah）が勝ち、出ていた変換が崩れる。
    /// かなに読める 1 文字（3i の i）は打ちかけではないので引く
    static let singleLetterEnglishPenalty = 3.0
    /// 利用者の辞書で英語として扱う打鍵の区間の評価値の下限と、日本語として扱う読めない打鍵の区間の評価値。
    /// かな漢字変換に入れた利用者の語 1 つの点の基準（登録数による減点と前後の連接を除いたもの）から作り、登録数によらず一定にする
    static let registeredScore = LatticeConverter.userWordValue - japaneseSpanPenalty

    /// 句読点で切った部分ごとに、表示にして文として比べる区切りの候補の数の既定値。1 なら比べずに採点の点が最も高い区切りにする。
    /// 値は打鍵ごとの表示の時間で決める（proposals/model-judged-segmentation.md）
    public static let defaultJudgedCandidates = 2
    /// 句読点で切った部分ごとに、表示にして文として比べる区切りの候補の数
    public var judgedCandidates = Segmenter.defaultJudgedCandidates

    /// 句読点か記号の手前で終わる部分の、区切りと表示。未確定の文字列の寿命だけ持つ
    var closedRuns: [RunKey: (segments: [Segment], text: String)] = [:]
    /// 英語にも日本語にも読める語を前から決めていく途中の段の結果。段は、部分をその語の終わりまで打った入力で、
    /// 打鍵ごとに同じ段を計算し直さないために未確定の文字列の寿命だけ持つ。結果は入力だけで決まり、覚えていなくても同じになる
    var wordSteps: [RunKey: WordStep] = [:]

    /// 語を決める 1 つの段の結果。best は選んだ区切り、beam は次の段に残す語の割り当て
    struct WordStep {
        var best: [Segment]
        var beam: [[WordSpan: Bool]]
    }

    struct RunKey: Hashable {
        var input: String
        var leading: JapaneseContext
        var offset: Int
        var ending: JapaneseEnding
        var left: String
    }

    struct WordSpan: Hashable {
        var start: Int
        var text: String
        var range: Range<Int> { start..<(start + text.count) }
    }

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
        segment(input, after: leading.continuation, context: leading.japaneseContext, left: leading.text)
    }

    /// 区切りを決めた部分の採点で比べた区間の候補を返す。句読点の前で英語に続くと分かって採点し直す部分の候補は含めない。診断用
    public func candidates(_ input: String, leading: Leading = .start) -> [ScoredSpan] {
        var spans: [ScoredSpan] = []
        _ = segment(input, after: leading.continuation, context: leading.japaneseContext, left: leading.text) { spans.append($0) }
        return spans
    }

    /// context は、最初の句読点か記号までの部分の最初の日本語区間を評価する形。left は入力の前に表示している文字列で、区切りの候補を文として比べるときの左の文脈
    func segment(_ input: String, after continuation: Continuation, context: JapaneseContext, left: String) -> [Segment] {
        segment(input, after: continuation, context: context, left: left, observe: nil)
    }

    /// observe には、区切りを決めた部分の区間の候補だけを渡す。句読点の前で英語に続くと分かって採点し直す部分の候補は渡さない。
    /// 句読点と記号で切った部分ごとに、区切りの候補を judge で 1 つに決める。前の部分の表示は、後ろの部分の左の文脈になる
    private func segment(_ input: String, after continuation: Continuation, context: JapaneseContext, left: String, observe: ((ScoredSpan) -> Void)?) -> [Segment] {
        let chars = Array(input)
        var segments: [Segment] = []
        var shown = left
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
            let before = closedRun(String(chars[runStart..<i]), leading: runContext, offset: runStart, ending: .beforeMark(mark), observe: collect, left: shown)
            let previousIsEnglish = before.segments.last.map { $0.kind == .english } ?? (runContinuation == .afterEnglish)
            if symbol == nil, previousIsEnglish { continue }
            runSpans.forEach { observe?($0) }
            segments += before.segments
            segments.append(Segment(kind: .punctuation, source: key, reading: mark, output: mark, score: 0, context: .start))
            shown += before.text + mark
            runStart = end
            runContinuation = Self.continuation(after: key)
            runContext = runContinuation.japaneseContext
        }
        return segments + judgeRun(String(chars[runStart...]), leading: runContext, offset: runStart, ending: .open, observe: observe, left: shown)
    }

    /// 句読点か記号の手前で終わる部分の judgeRun と、その表示。表示は後ろの部分の左の文脈になる。
    /// 後ろに打鍵が続いても部分の中身は変わらないので、未確定の文字列の間は 1 回だけ計算する。observe があるとき（診断）は覚えたものを使わない
    private func closedRun(_ input: String, leading: JapaneseContext, offset: Int, ending: JapaneseEnding, observe: ((ScoredSpan) -> Void)?, left: String) -> (segments: [Segment], text: String) {
        let key = RunKey(input: input, leading: leading, offset: offset, ending: ending, left: left)
        if observe == nil, judgeObserver == nil, let cached = closedRuns[key] { return cached }
        let segments = judgeRun(input, leading: leading, offset: offset, ending: ending, observe: observe, left: left)
        let result = (segments, shownText(segments, left: left))
        closedRuns[key] = result
        return result
    }

    /// 句読点を含まない部分の区切りの候補を作り、文として最も確からしいものに決める。
    /// 英語にも日本語にも読める語が無いか、変換器が文を評価するモデルを持たなければ、採点の点の上位 judgedCandidates 個を候補にする。
    /// あれば、利用者が前から打つのと同じ順に語を決めていく。部分を語の終わりまで打った入力を段とし、段ごとに wordStep で決める。
    /// 結果は入力だけで決まる。段の結果は覚えて使い回すので、1 打鍵ずつ打つときは新しく現れた段だけを計算する
    private func judgeRun(_ input: String, leading: JapaneseContext, offset: Int, ending: JapaneseEnding, observe: ((ScoredSpan) -> Void)?, left: String) -> [Segment] {
        let chars = Array(input)
        let registered = SpanConstraint(registered: registeredSpans(chars))
        let ranked = { self.judge(self.rankedCandidates(input, leading: leading, offset: offset, ending: ending, constraint: registered, observe: observe), left: left) }
        let words = ambiguousWords(chars).map { WordSpan(start: $0.start + offset, text: $0.text) }
        guard !words.isEmpty, japaneseConverter.evaluatesSentences else { return ranked() }
        // 診断（--lattice）には、語の英語か日本語かの条件を課さない採点で比べた区間の候補を渡す（登録した打鍵の条件は課す）
        if observe != nil { _ = rankedCandidates(input, leading: leading, offset: offset, ending: ending, constraint: registered, observe: observe) }
        // 診断（--stages）に渡すのは、部分そのものを決める最後の段だけにする
        let observer = judgeObserver
        judgeObserver = nil
        var beam: [[WordSpan: Bool]] = [[:]]
        for end in Set(words.map { $0.range.upperBound - offset }).sorted() where end < chars.count {
            beam = wordStep(String(chars[..<end]), leading: leading, offset: offset, ending: .open, left: left, beam: beam).beam
        }
        judgeObserver = observer
        return wordStep(input, leading: leading, offset: offset, ending: ending, left: left, beam: beam).best
    }

    /// 語を決める 1 つの段。beam の割り当てごとに、まだ決めていない語の英語か日本語かの組み合わせそれぞれの最良の区切りを候補にし、
    /// 文として最も確からしいものを選ぶ。候補を確からしさの順に decidedBeamWidth 個まで取り、段の中の最後に始まる語より前で終わる語の
    /// 英語か日本語かを、それぞれの割り当てに足して次の段に残す
    private func wordStep(_ input: String, leading: JapaneseContext, offset: Int, ending: JapaneseEnding, left: String, beam: [[WordSpan: Bool]]) -> WordStep {
        let key = RunKey(input: input, leading: leading, offset: offset, ending: ending, left: left)
        if judgeObserver == nil, let cached = wordSteps[key] { return cached }
        let registered = registeredSpans(Array(input))
        // 組み合わせを比べない段も、結果を覚えて打鍵ごとに計算し直さない
        let ranked = { () -> WordStep in
            let best = self.judge(self.rankedCandidates(input, leading: leading, offset: offset, ending: ending, constraint: SpanConstraint(registered: registered), observe: nil), left: left)
            let step = WordStep(best: best, beam: beam)
            self.wordSteps[key] = step
            return step
        }
        let words = ambiguousWords(Array(input)).map { WordSpan(start: $0.start + offset, text: $0.text) }
        let present = Set(words)
        var bases: [[WordSpan: Bool]] = []
        for base in beam.map({ $0.filter { present.contains($0.key) } }) where !bases.contains(base) { bases.append(base) }
        let local = { (word: WordSpan) in (word.range.lowerBound - offset)..<(word.range.upperBound - offset) }
        var candidates: [(segments: [Segment], base: [WordSpan: Bool])] = []
        for base in bases {
            let open = words.filter { base[$0] == nil }
            // 決めていない語が多すぎる段は、組み合わせを並べると止まるほど遅くなるので、採点の点で決める
            guard open.count <= Self.maxOpenWords else { continue }
            for mask in 0..<(1 << open.count) {
                let english = base.filter(\.value).map(\.key) + open.indices.filter { mask & (1 << $0) != 0 }.map { open[$0] }
                let notEnglish = base.filter { !$0.value }.map(\.key) + open.indices.filter { mask & (1 << $0) == 0 }.map { open[$0] }
                let constraint = SpanConstraint(english: english.map(local), notEnglish: notEnglish.map(local), registered: registered)
                guard let found = segmentRun(input, leading: leading, offset: offset, ending: ending, width: 1, constraint: constraint, observe: nil).first else { continue }
                let key = found.map { "\($0.kind)\($0.source)" }
                guard !candidates.contains(where: { $0.segments.map { "\($0.kind)\($0.source)" } == key }) else { continue }
                candidates.append((found, base))
            }
        }
        // 前の段で決めた語が、続けて打った綴りと両立しないとき（mode と決めた後に modem）は、条件を課さない
        guard !candidates.isEmpty else { return ranked() }
        let texts = shownTexts(candidates.map(\.segments), left: left)
        // 文が長すぎてモデルが測れなければ、採点の点で決める
        guard let values = japaneseConverter.naturalness(texts: texts, left: left) else { return ranked() }
        let order = candidates.indices.sorted { values[$0] > values[$1] }
        judgeObserver?(candidates.map(\.segments), left, order[0])
        let lastStart = words.map(\.start).max()!
        var next: [[WordSpan: Bool]] = []
        for i in order {
            var position = offset
            var englishRanges: Set<Range<Int>> = []
            for segment in candidates[i].segments {
                if segment.kind == .english { englishRanges.insert(position..<(position + segment.source.count)) }
                position += segment.source.count
            }
            var assignment = candidates[i].base
            for word in words where assignment[word] == nil && word.range.upperBound <= lastStart {
                assignment[word] = englishRanges.contains(word.range)
            }
            guard !next.contains(assignment) else { continue }
            next.append(assignment)
            if next.count == Self.decidedBeamWidth { break }
        }
        let step = WordStep(best: candidates[order[0]].segments, beam: next)
        wordSteps[key] = step
        return step
    }

    /// 前の段までに決めた語の割り当てを残す数。1 つだけ残すと、後ろの語を打つ前に決めた前の語（modebetuni の mode）を選び直せない
    private static let decidedBeamWidth = 2
    /// 1 つの段で組み合わせを並べる、決めていない語の数の上限。組み合わせは語の数の 2 乗ではなく 2 の累乗で増えるので、
    /// 上限を超える段は組み合わせを並べない。値は打鍵ごとの表示の時間で決める設定（PRINCIPLES.md）
    private static let maxOpenWords = 6

    /// 英語にも日本語にも読める語。綴りの表で全体がかなに読め、英語の語の表にあり、英語にしない短い綴りより長いもの。位置は chars の中
    private func ambiguousWords(_ chars: [Character]) -> [(start: Int, text: String)] {
        var words: [(start: Int, text: String)] = []
        for start in chars.indices {
            for end in stride(from: start + Self.maxJapaneseFirstLength + 1, through: min(chars.count, start + Self.maxAmbiguousWordLength), by: 1) {
                let text = String(chars[start..<end])
                guard typedWords[text] == nil, english.isWord(text), table.reading(of: text) != nil else { continue }
                words.append((start, text))
            }
        }
        return words
    }

    /// 英語にも日本語にも読める語として探す綴りの長さの上限
    private static let maxAmbiguousWordLength = 12

    /// 区切りに課す条件。english の範囲はちょうどその範囲の英語区間にし、notEnglish の範囲はちょうどその範囲の英語区間にしない。
    /// registered の words の範囲には日本語区間を重ねない（英語区間か利用者の語の区間で覆う）。japanese の範囲には英語区間を重ねない
    private struct SpanConstraint {
        var english: [Range<Int>] = []
        var notEnglish: [Range<Int>] = []
        var registered = RegisteredSpans()

        func allows(_ range: Range<Int>, kind: Segment.Kind) -> Bool {
            for forced in english where forced.overlaps(range) {
                guard kind == .english, forced == range else { return false }
            }
            if kind == .japanese, registered.words.contains(where: { $0.overlaps(range) }) { return false }
            if kind == .english, registered.japanese.contains(where: { $0.overlaps(range) }) { return false }
            return !(kind == .english && notEnglish.contains(range))
        }
    }

    /// 利用者の辞書に登録した打鍵の範囲。words は英語の語とかなに読めない日本語の語、japanese はかなに読める日本語の語
    private struct RegisteredSpans {
        var words: [Range<Int>] = []
        var japanese: [Range<Int>] = []
    }

    /// 採点の点の上位 judgedCandidates 個の区切り。constraint を満たす区切りが無ければ、条件を課さずに採る
    private func rankedCandidates(_ input: String, leading: JapaneseContext, offset: Int, ending: JapaneseEnding, constraint: SpanConstraint, observe: ((ScoredSpan) -> Void)?) -> [[Segment]] {
        let found = segmentRun(input, leading: leading, offset: offset, ending: ending, width: judgedCandidates, constraint: constraint, observe: observe)
        return found.isEmpty ? segmentRun(input, leading: leading, offset: offset, ending: ending, width: judgedCandidates, constraint: nil, observe: nil) : found
    }

    /// 利用者の辞書に登録した打鍵とちょうど一致し、両側が区切りの端（部分の先頭か末尾、句読点、空白）の範囲。
    /// 登録した打鍵は利用者が決めた語なので、日本語の読みと点で比べさせない。語の途中で一致したもの（sukinanodesu の node）は含めない
    private func registeredSpans(_ chars: [Character]) -> RegisteredSpans {
        // 範囲の両側は区切りの端なので、端の位置の組ごとに辞書を引けば足りる。費用は登録した語の数によらない
        let breaks = chars.indices.filter { chars[$0] == " " || Self.punctuation[chars[$0]] != nil }
        let starts = [0] + breaks.map { $0 + 1 }
        let ends = breaks + [chars.count]
        var spans = RegisteredSpans()
        for start in starts {
            for end in ends where end > start {
                let keys = String(chars[start..<end])
                if typedWords[keys] != nil || typedJapaneseWords[keys] != nil { spans.words.append(start..<end) }
                if typedReadableJapanese.contains(keys) { spans.japanese.append(start..<end) }
            }
        }
        return spans
    }

    /// 区切りの候補のうち、表示にした文が left に続く文として最も確からしいもの。候補は採点の点の高い順に並ぶ。
    /// 文法として成り立つ候補が複数あるとき、選択を変換器のモデルによる文の評価で行う（PRINCIPLES.md）。
    /// 候補が 1 つか、変換器が文を評価するモデルを持たなければ、採点の点が最も高い候補にする
    private func judge(_ candidates: [[Segment]], left: String) -> [Segment] {
        let chosen = chosenCandidate(candidates, left: left)
        judgeObserver?(candidates, left, chosen)
        return candidates[chosen]
    }

    /// judge が選ぶ候補の番号
    private func chosenCandidate(_ candidates: [[Segment]], left: String) -> Int {
        guard candidates.count > 1, japaneseConverter.evaluatesSentences else { return 0 }
        // 文が長すぎてモデルが測れなければ、採点の点で決める
        guard let values = japaneseConverter.naturalness(texts: shownTexts(candidates, left: left), left: left) else { return 0 }
        return values.indices.max { values[$0] < values[$1] }!
    }

    /// 診断用に、judge が比べた候補と左の文脈と選んだ番号を受け取る
    private var judgeObserver: (([[Segment]], String, Int) -> Void)?

    /// 区切りの候補を比べた、句読点で切った 1 つの部分。診断用
    public struct Judgement: Sendable {
        /// 区切りの候補。英語にも日本語にも読める語の無い部分は採点の点の高い順、ある部分は語の割り当てと組み合わせの順
        public var candidates: [[Segment]]
        /// 候補ごとの、区切りの採点で辞書の変換が作った表記をつないだ文と、その文の確からしさ
        public var dictionaryTexts: [String]
        public var dictionaryValues: [Double]?
        /// 候補ごとの、表示の変換（モデル）が書いた表記をつないだ文と、その文の確からしさ
        public var shownTexts: [String]
        public var shownValues: [Double]?
        /// 選んだ候補の番号
        public var chosen: Int
    }

    /// 区切りの候補を比べた部分ごとの、候補・比べた文・文の確からしさ・選んだ候補。区切りと同じ計算をたどる。診断用
    public func judgements(_ input: String, leading: Leading = .start) -> [Judgement] {
        var seen: [([[Segment]], String, Int)] = []
        judgeObserver = { seen.append(($0, $1, $2)) }
        defer { judgeObserver = nil }
        _ = segment(input, leading: leading)
        return seen.map { candidates, left, chosen in
            let dictionaryTexts = candidates.map { $0.map(\.output).joined() }
            let shownTexts = candidates.map { shownText($0, left: left) }
            return Judgement(
                candidates: candidates,
                dictionaryTexts: dictionaryTexts,
                dictionaryValues: japaneseConverter.naturalness(texts: dictionaryTexts, left: left),
                shownTexts: shownTexts,
                shownValues: japaneseConverter.naturalness(texts: shownTexts, left: left),
                chosen: chosen
            )
        }
    }

    /// 区間を表示にした文字列。日本語区間は left に前の区間の表示をつないだものを左の文脈にして表示の変換にする
    private func shownText(_ segments: [Segment], left: String) -> String {
        zip(segments, displays(of: segments.map(ShownSpan.init), left: left)).map { segment, display in display?.text ?? segment.output }.joined()
    }

    /// candidates のそれぞれの shownText。候補ごとに前から順に表示にするのは shownText と同じで、
    /// 各候補の次の日本語区間を 1 回の表示の変換にまとめて渡し、候補どうしを同時に計算させる
    private func shownTexts(_ candidates: [[Segment]], left: String) -> [String] {
        var texts = Array(repeating: "", count: candidates.count)
        var next = Array(repeating: 0, count: candidates.count)
        while true {
            var waiting: [(candidate: Int, request: DisplayRequest)] = []
            for c in candidates.indices {
                while next[c] < candidates[c].count {
                    let segment = candidates[c][next[c]]
                    guard segment.kind == .japanese else {
                        texts[c] += segment.output
                        next[c] += 1
                        continue
                    }
                    waiting.append((c, DisplayRequest(kana: segment.reading, context: segment.context, left: left + texts[c])))
                    break
                }
            }
            guard !waiting.isEmpty else { return texts }
            for ((c, request), display) in zip(waiting, japaneseConverter.displays(waiting.map(\.request))) {
                guard let display else { preconditionFailure("日本語区間の表示の変換が無い: \(request.kana)") }
                texts[c] += display.text
                next[c] += 1
            }
        }
    }

    /// i から始まる記号の打鍵のうち最も長いもの
    static func symbol(at i: Int, in chars: [Character]) -> (key: String, mark: String)? {
        for length in stride(from: min(maxSymbolLength, chars.count - i), through: 1, by: -1) {
            let key = String(chars[i..<(i + length)])
            if let mark = symbols[key] { return (key, mark) }
        }
        return nil
    }

    /// 句読点と記号の打鍵から作る日本語の記号。読みにも表示にも、打った順にそのまま出る
    public static let marks = Set((Array(punctuation.values) + Array(symbols.values)).joined())

    /// 最後の句読点か記号の打鍵の終わりの位置。無ければ 0
    public static func lastMarkEnd(in chars: [Character]) -> Int {
        var last = 0
        var i = 0
        while i < chars.count {
            let key = symbol(at: i, in: chars)?.key ?? String(chars[i])
            if symbols[key] != nil || punctuation[chars[i]] != nil { last = i + key.count }
            i += key.count
        }
        return last
    }

    /// 区切りの DP の状態。日本語区間の終わりのつながりは後ろに続くもので変わるので、後ろに英語区間か利用者の語の区間が続くときの点を、
    /// 後ろに日本語区間が続くか input の終わりに来るときの点と分けて持つ
    private enum Slot: Hashable {
        case kind(Segment.Kind)
        case japaneseBeforeWord

        var kind: Segment.Kind {
            switch self {
            case .kind(let kind): kind
            case .japaneseBeforeWord: .japanese
            }
        }
    }

    /// 区切りの候補を見分ける印。日本語区間に続く日本語区間は採点のための切れ目で、まとめて 1 つの区間に戻すので印を足さない。
    /// 印の並びが同じ区切りは、まとめた後に同じ区間の並びになる
    private struct Mark: Hashable {
        var kind: Segment.Kind
        var start: Int
    }

    /// 句読点を含まない部分を、日本語区間と英語区間の並びに分けた候補。採点の点の高い順に、まとめた後の区間の並びが違うものを judgedCandidates 個まで返す。
    /// 空でない入力には、どの候補も 1 つ以上の区間を持つ。空の入力には区間の無い候補を 1 つ返す。
    /// offset は input が入力全体のどの位置から始まるかで、observe に渡す区間の候補の位置に足す。
    /// ending は input の後ろに続くもの。input が入力の末尾までなら open、句読点か記号の手前までならその記号
    private func segmentRun(_ input: String, leading: JapaneseContext, offset: Int, ending: JapaneseEnding, width requested: Int, constraint: SpanConstraint?, observe: ((ScoredSpan) -> Void)?) -> [[Segment]] {
        let chars = Array(input)
        let n = chars.count
        guard n > 0 else { return [[]] }
        let endsInput = ending == .open
        let width = max(1, requested)

        // best[位置][状態] = 評価値の高い順の、印の並びが違う区切り width 個まで。英語区間は英語区間に続けない。日本語区間は日本語区間にも続けられる
        struct Cell {
            var score: Double
            var segment: Segment
            var from: Int
            var previous: (slot: Slot, rank: Int)?
            var marks: [Mark]
        }
        var best: [[Slot: [Cell]]] = Array(repeating: [:], count: n + 1)
        let origin = [Cell(score: 0, segment: Segment(kind: .punctuation, source: "", reading: "", output: "", score: 0, context: leading), from: 0, previous: nil, marks: [])]

        /// pos で終わる、直前の状態が previous の区切り。pos が 0 なら入力の先頭（前の状態なし）だけ
        func cells(at pos: Int, after previous: Slot?) -> [Cell] {
            if pos == 0 { return previous == nil ? origin : [] }
            guard let previous else { return [] }
            return best[pos][previous] ?? []
        }

        func relax(_ end: Int, _ start: Int, _ segment: Segment, after previous: Slot?, into slot: Slot) {
            if let constraint, !constraint.allows(start..<end, kind: segment.kind) { return }
            let bases = cells(at: start, after: previous)
            guard !bases.isEmpty else { return }
            observe?(ScoredSpan(start: offset + start, end: offset + end, after: previous?.kind, segment: segment))
            for (rank, base) in bases.enumerated() {
                let continuing = segment.kind == .japanese && base.marks.last?.kind == .japanese
                let cell = Cell(
                    score: base.score + segment.score,
                    segment: segment,
                    from: start,
                    previous: previous.map { ($0, rank) },
                    marks: continuing ? base.marks : base.marks + [Mark(kind: segment.kind, start: start)]
                )
                var list = best[end][slot] ?? []
                if let same = list.firstIndex(where: { $0.marks == cell.marks }) {
                    guard list[same].score < cell.score else { continue }
                    list.remove(at: same)
                }
                let at = list.firstIndex { $0.score < cell.score } ?? list.count
                guard at < width else { continue }
                list.insert(cell, at: at)
                if list.count > width { list.removeLast() }
                best[end][slot] = list
            }
        }

        // 位置ごとの、綴りの表で最後まで読める終端とかな
        let readingsAt = (0..<n).map { table.readings(from: $0, in: chars) }
        // 位置ごとの、日本語区間に続く日本語区間の連なりで届く終端。採点する読みの長さを超える区間も、
        // 日本語区間の連なりとして採れるなら日本語として採れるものとして英語区間を締め出す
        var chained: [Set<Int>] = Array(repeating: [], count: n + 1)
        for start in stride(from: n - 1, through: 1, by: -1) {
            for (end, kana) in readingsAt[start] where Self.isScoredJapanese(kana) {
                guard japaneseConverter.convert(kana: kana, context: .start, ending: .open) != nil else { continue }
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
            let predecessors: [(slot: Slot?, context: JapaneseContext, penalty: Double)] = start == 0
                ? [(nil, leading, Self.japaneseSpanPenalty)]
                : [(.kind(.english), context, Self.japaneseSpanPenalty), (.kind(.japanese), .start, Self.continuingJapanesePenalty), (.kind(.word), context, Self.japaneseSpanPenalty)]
            // 日本語区間が英語区間か利用者の語の区間の後ろに来るときの、前の日本語区間の状態
            let wordPredecessors: [Slot?] = start == 0 ? [nil] : [.japaneseBeforeWord, .kind(.word)]
            let readings = readingsAt[start]
            // この位置から綴りの表で最後まで読める終端。英語区間の候補が読める綴りかを引くのに使う
            let readableEnds = Set(readings.map(\.end))
            for (end, kana) in readings where Self.isScoredJapanese(kana) {
                // input の終わりで終わる区間は input の後ろに続くものとつなぐ。途中で終わる区間は、後ろの日本語区間と後でまとめるか、英語区間か語の区間が続く
                let endings: [(ending: JapaneseEnding, slot: Slot)] = end == n
                    ? [(ending, .kind(.japanese))]
                    : [(.open, .kind(.japanese)), (.beforeWord, .japaneseBeforeWord)]
                for predecessor in predecessors {
                    guard !cells(at: start, after: predecessor.slot).isEmpty else { continue }
                    for (spanEnding, slot) in endings {
                        guard let segment = japaneseSegment(String(chars[start..<end]), kana: kana, context: predecessor.context, ending: spanEnding, penalty: predecessor.penalty)
                        else { continue }
                        japaneseEnds.insert(end)
                        relax(end, start, segment, after: predecessor.slot, into: slot)
                    }
                }
            }
            let japaneseReach = japaneseEnds.reduce(into: japaneseEnds) { $0.formUnion(chained[$1]) }
            // 句読点は前の語の後ろに付くので、英語区間を句読点から始めない。入力の先頭は、入力欄の前の英語に付いている
            if start > 0, Self.punctuation[chars[start]] != nil { continue }
            for end in (start + 1)...n {
                let source = String(chars[start..<end])
                if let segment = wordSegment(source, context: context) {
                    for previous in start == 0 ? [nil] : wordPredecessors + [.kind(.english)] {
                        relax(end, start, segment, after: previous, into: .kind(.word))
                    }
                    continue
                }
                if prefersJapanese(source, readable: readableEnds.contains(end)), japaneseReach.contains(end) { continue }
                for previous in wordPredecessors {
                    relax(end, start, englishSegment(source, context: context, atInputEnd: endsInput && end == n), after: previous, into: .kind(.english))
                }
            }
        }

        // 入力の終わりの状態をまたいで、印の並びが違う区切りを点の高い順に width 個まで取る
        var finals: [Cell] = []
        for cell in best[n].values.flatMap({ $0 }).sorted(by: { $0.score > $1.score }) where finals.count < width {
            guard !finals.contains(where: { $0.marks == cell.marks }) else { continue }
            finals.append(cell)
        }
        // どの区間も、日本語として採れなければ英語として採れるので、空でない入力には必ず区切りがある
        // 条件を課したときは、条件を満たす区切りが無いことがある
        if finals.isEmpty, constraint != nil { return [] }
        precondition(!finals.isEmpty, "区切りが見つからない: \(input)")
        return finals.map { final in
            var segments: [Segment] = [final.segment]
            var cell = final
            while let previous = cell.previous {
                cell = best[cell.from][previous.slot]![previous.rank]
                segments.append(cell.segment)
            }
            precondition(cell.from == 0, "区切りが入力の先頭まで辿れない: \(input)")
            return mergeJapanese(segments.reversed(), ending: ending)
        }
    }

    /// source の全体を 1 区間として、日本語区間と英語区間のうち評価値の高い方にする。区切りの選択と同じく、
    /// 利用者の辞書で日本語として扱う読めない打鍵ならその語の区間、読めない箇所を含めば英語、日本語として採れて英語にしない綴りなら日本語にする
    func singleSpan(_ source: String, context: JapaneseContext) -> Segment {
        if let word = wordSegment(source, context: context) { return word }
        let english = englishSegment(source, context: context, atInputEnd: false)
        guard let kana = table.reading(of: source), Self.canBeJapanese(kana),
              let japanese = japaneseSegment(source, kana: kana, context: context, ending: .open, penalty: Self.japaneseSpanPenalty)
        else { return english }
        return prefersJapanese(source, readable: true) || japanese.score >= english.score ? japanese : english
    }

    /// 1 つのかなになる綴り（ga to de no）、読める 2 文字以下の綴り（ie）、読めて英語の語でない綴り（utte deno matte）は、
    /// 日本語として採れるなら英語にしない。利用者の辞書で英語として扱う打鍵は、どれにも当たらない
    func prefersJapanese(_ source: String, readable: Bool) -> Bool {
        guard typedWords[source] == nil else { return false }
        return table.isSingleKana(source) || (readable && (source.count <= Self.maxJapaneseFirstLength || !english.isWord(source)))
    }

    private func japaneseSegment(_ source: String, kana: String, context: JapaneseContext, ending: JapaneseEnding, penalty: Double) -> Segment? {
        guard let reading = japaneseConverter.convert(kana: kana, context: context, ending: ending) else { return nil }
        let score = reading.value - penalty
        return Segment(kind: .japanese, source: source, reading: kana, output: reading.text, score: score, context: reading.context)
    }

    /// 利用者の辞書で日本語として扱う、かなに読めない打鍵にちょうど一致すれば、最初に登録した語の区間
    private func wordSegment(_ source: String, context: JapaneseContext) -> Segment? {
        typedJapaneseWords[source].map { Segment(kind: .word, source: source, reading: source, output: $0[0], score: Self.registeredScore, context: context) }
    }

    private func englishSegment(_ source: String, context: JapaneseContext, atInputEnd: Bool) -> Segment {
        let letters = source.filter(\.isLetter)
        let typingSpelling = atInputEnd && source.last?.isLetter == true && table.reading(of: letters) == nil
        let singleLetter = letters.count == 1 && !typingSpelling ? Self.singleLetterEnglishPenalty : 0
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
    /// まとめた区間の点は、区切りを決めた区間ごとの点の和にする。まとめた読みの終わりは、まとめた最後の区間の後ろに続くものとつなぐ。
    /// ending は segments の後ろに続くもの
    private func mergeJapanese(_ segments: [Segment], ending: JapaneseEnding) -> [Segment] {
        var merged: [Segment] = []
        for (i, segment) in segments.enumerated() {
            guard segment.kind == .japanese, let last = merged.last, last.kind == .japanese else {
                merged.append(segment)
                continue
            }
            let reading = last.reading + segment.reading
            let next = segments.indices.contains(i + 1) ? segments[i + 1] : nil
            let following: JapaneseEnding = switch next?.kind {
            case nil: ending
            case .japanese: .open
            default: .beforeWord
            }
            guard let whole = japaneseConverter.convert(kana: reading, context: last.context, ending: following) else {
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
