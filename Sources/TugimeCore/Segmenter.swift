import Foundation

public struct Segment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        /// 日本語の記号にした句読点（, . ? ! ~）と記号の打鍵（zh [ / など）
        case punctuation
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

/// 日本語区間と英語区間の評価値を同じ尺度に揃える重み
public struct SegmentWeights: Sendable {
    public var japanese: Double
    public var english: Double
    /// 区間を 1 つ増やすごとに引く値
    public var japaneseSpanPenalty: Double
    public var englishSpanPenalty: Double

    public init(japanese: Double, english: Double, japaneseSpanPenalty: Double, englishSpanPenalty: Double) {
        self.japanese = japanese
        self.english = english
        self.japaneseSpanPenalty = japaneseSpanPenalty
        self.englishSpanPenalty = englishSpanPenalty
    }

    /// corpus/examples.tsv に対して tugime-cli --tune で選ぶ値
    public static let standard = SegmentWeights(
        japanese: 1.0,
        english: 1.4,
        japaneseSpanPenalty: 3,
        englishSpanPenalty: -2
    )
}

/// 打鍵列の全体を、日本語区間と英語区間の並びとして最も自然に読める区切りに分ける。
/// 綴りの表で読めない箇所は日本語区間に入れられないので、そこは必ず英語になる。
/// 読める箇所は、日本語として変換した評価値と英語の綴りとしての評価値を比べて決める。
public final class Segmenter {
    let table: RomajiTable
    private let english: EnglishModel
    let japaneseConverter: any JapaneseConverting
    public var weights: SegmentWeights

    public init(table: RomajiTable, english: EnglishModel, japanese: any JapaneseConverting, weights: SegmentWeights = .standard) {
        self.table = table
        self.english = english
        self.japaneseConverter = japanese
        self.weights = weights
    }

    /// 入力の前に何があるか
    public enum Leading: Sendable, Equatable {
        /// 文頭。前に何も無いか、空白・改行・文末の記号の後
        case start
        /// 日本語の文の途中
        case afterJapanese
        /// 英字・数字・記号など ASCII の後
        case afterEnglish

        /// 最初の日本語区間の評価のしかた
        var japaneseContext: JapaneseContext { self == .start ? .start : .afterCaret }
    }

    /// 英語区間に続く日本語区間の評価のしかた。英語区間が数字で終わるなら、その数字に続く形（1500 円、3 回）にする
    static func context(after text: some Collection<Character>) -> JapaneseContext {
        let digits = String(text.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        return digits.isEmpty ? .afterWord : .afterNumber(digits)
    }

    /// 打っている途中に変換して見せる日本語区間の、かなの最短の長さ。短い断片は的外れな漢字になりやすい（きょ → 居）ので、それより短い区間はかなのまま見せる
    static let liveConversionMinLength = 4

    /// 打っている途中に見せる文字列。Enter で確定するのもこれ。日本語区間は長ければ変換し、短ければかなのまま、英語区間は打ったまま。
    /// かなのまま見せるのは見た目だけで、後ろの区間の左の文脈には変換した表記を渡す
    public func liveText(_ input: String, leading: Leading = .start) -> String {
        let segments = segment(input, leading: leading)
        return zip(segments, displays(of: segments.map(ShownSpan.init))).map { segment, display in
            guard let display else { return segment.output }
            return segment.reading.count < Self.liveConversionMinLength ? segment.reading : display.text
        }.joined()
    }

    /// 日本語区間をすべて表示の変換にした文字列
    public func displayText(_ input: String, leading: Leading = .start) -> String {
        let segments = segment(input, leading: leading)
        return zip(segments, displays(of: segments.map(ShownSpan.init))).map { segment, display in
            display?.text ?? segment.output
        }.joined()
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
    func displays(of spans: [ShownSpan], left: String = "") -> [JapaneseDisplay?] {
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
    static func leading(after key: String) -> Leading {
        symbols[key] == nil ? .start : .afterJapanese
    }

    /// 句読点は前の語の後ろに付くので、直前が日本語なら日本語の記号にし、英語なら打ったまま英語の区間に含める。
    /// 記号の打鍵は、前後によらず記号にする。入力の先頭の句読点は、入力欄の直前（leading）で決める。
    /// 日本語の記号の位置で入力を切る。句読点の後は文頭として、記号の打鍵の後は文の途中かもしれないものとして次の部分を評価する
    public func segment(_ input: String, leading: Leading = .start) -> [Segment] {
        segment(input, leading: leading, context: leading.japaneseContext)
    }

    /// context は、最初の句読点か記号までの部分の最初の日本語区間を評価する形
    func segment(_ input: String, leading: Leading, context: JapaneseContext) -> [Segment] {
        let chars = Array(input)
        var segments: [Segment] = []
        var runStart = 0
        var runLeading = leading
        var runContext = context
        var i = 0
        while i < chars.count {
            let symbol = Self.symbol(at: i, in: chars)
            let key = symbol?.key ?? String(chars[i])
            let mark = symbol?.mark ?? Self.punctuation[chars[i]]
            let end = i + key.count
            defer { i = end }
            guard let mark else { continue }
            let before = segmentRun(String(chars[runStart..<i]), leading: runContext)
            let previousIsEnglish = before.last.map { $0.kind == .english } ?? (runLeading == .afterEnglish)
            if symbol == nil, previousIsEnglish { continue }
            segments += before
            segments.append(Segment(kind: .punctuation, source: key, reading: mark, output: mark, score: 0, context: .start))
            runStart = end
            runLeading = Self.leading(after: key)
            runContext = runLeading.japaneseContext
        }
        return segments + segmentRun(String(chars[runStart...]), leading: runContext)
    }

    /// i から始まる記号の打鍵のうち最も長いもの
    private static func symbol(at i: Int, in chars: [Character]) -> (key: String, mark: String)? {
        for length in stride(from: min(maxSymbolLength, chars.count - i), through: 1, by: -1) {
            let key = String(chars[i..<(i + length)])
            if let mark = symbols[key] { return (key, mark) }
        }
        return nil
    }

    /// 句読点を含まない部分を、日本語区間と英語区間の並びに分ける。空でない入力には必ず 1 つ以上の区間を返す
    private func segmentRun(_ input: String, leading: JapaneseContext) -> [Segment] {
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
            let predecessors: [(kind: Segment.Kind?, context: JapaneseContext)] = start == 0
                ? [(nil, leading)]
                : [(.english, context), (.japanese, .start)]
            let readings = readingsAt[start]
            // この位置から綴りの表で最後まで読める終端。英語区間の候補が読める綴りかを引くのに使う
            let readableEnds = Set(readings.map(\.end))
            for (end, kana) in readings where Self.isScoredJapanese(kana) {
                for predecessor in predecessors {
                    guard score(at: start, after: predecessor.kind) != nil,
                          let segment = japaneseSegment(String(chars[start..<end]), kana: kana, context: predecessor.context) else { continue }
                    japaneseEnds.insert(end)
                    relax(end, start, segment, after: predecessor.kind)
                }
            }
            let japaneseReach = japaneseEnds.reduce(into: japaneseEnds) { $0.formUnion(chained[$1]) }
            // 句読点は前の語の後ろに付くので、英語区間を句読点から始めない。入力の先頭は、入力欄の前の英語に付いている
            if start > 0, Self.punctuation[chars[start]] != nil { continue }
            for end in (start + 1)...n {
                let source = String(chars[start..<end])
                if prefersJapanese(source, readable: readableEnds.contains(end)), japaneseReach.contains(end) { continue }
                relax(end, start, englishSegment(source, context: context), after: start == 0 ? nil : .japanese)
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
    /// 読めない箇所を含めば英語、日本語として採れて英語にしない綴りなら日本語にする
    func singleSpan(_ source: String, context: JapaneseContext) -> Segment {
        let english = englishSegment(source, context: context)
        guard let kana = table.reading(of: source), Self.canBeJapanese(kana),
              let japanese = japaneseSegment(source, kana: kana, context: context)
        else { return english }
        return prefersJapanese(source, readable: true) || japanese.score >= english.score ? japanese : english
    }

    /// 1 つのかなになる綴り（ga to de no）、読める 2 文字以下の綴り（ie）、読めて英語の語でない綴り（utte deno matte）は、
    /// 日本語として採れるなら英語にしない
    private func prefersJapanese(_ source: String, readable: Bool) -> Bool {
        table.isSingleKana(source) || (readable && (source.count <= Self.maxJapaneseFirstLength || !english.isWord(source)))
    }

    private func japaneseSegment(_ source: String, kana: String, context: JapaneseContext) -> Segment? {
        guard let reading = japaneseConverter.convert(kana: kana, context: context) else { return nil }
        let score = weights.japanese * reading.value - weights.japaneseSpanPenalty
        return Segment(kind: .japanese, source: source, reading: kana, output: reading.text, score: score, context: reading.context)
    }

    private func englishSegment(_ source: String, context: JapaneseContext) -> Segment {
        let score = weights.english * english.logProbability(source) - weights.englishSpanPenalty
        return Segment(kind: .english, source: source, reading: source, output: source, score: score, context: context)
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
