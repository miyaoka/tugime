import Foundation

public struct Segment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        /// 日本語の句読点にした , と .
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

    /// corpus/examples.tsv に対して tugime-cli --tune で選んだ値。近傍の組でも一致件数が落ちにくい場所から採る
    public static let standard = SegmentWeights(
        japanese: 1.0,
        english: 1.4,
        japaneseSpanPenalty: 3,
        englishSpanPenalty: -2
    )
}

/// 打鍵列の全体を、日本語区間と英語区間が交互に並ぶ列として最も自然に読める区切りに分ける。
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
        var japaneseContext: JapaneseContext { self == .start ? .start : .afterWord }
    }

    /// この長さ以下の読める綴りは、英語の語表に載っていても日本語として読む
    static let maxJapaneseFirstLength = 2

    /// 前の語の後ろに付く記号と、日本語の文で使う形
    static let punctuation: [Character: String] = [",": "、", ".": "。", "?": "？", "!": "！"]

    /// 記号は前の語の後ろに付くので、直前が日本語なら日本語の記号にし、英語なら打ったまま英語の区間に含める。
    /// 入力の先頭の記号は、入力欄の直前（leading）で決める。日本語の記号の位置で入力を切り、次の部分は文頭から評価する
    public func segment(_ input: String, leading: Leading = .start) -> [Segment] {
        let chars = Array(input)
        var segments: [Segment] = []
        var runStart = 0
        var runLeading = leading
        for (i, ch) in chars.enumerated() {
            guard let mark = Self.punctuation[ch] else { continue }
            let before = segmentRun(String(chars[runStart..<i]), leading: runLeading.japaneseContext)
            let previousIsEnglish = before.last.map { $0.kind == .english } ?? (runLeading == .afterEnglish)
            if previousIsEnglish { continue }
            segments += before
            segments.append(Segment(kind: .punctuation, source: String(ch), reading: mark, output: mark, score: 0))
            runStart = i + 1
            runLeading = .start
        }
        return segments + segmentRun(String(chars[runStart...]), leading: runLeading.japaneseContext)
    }

    /// 句読点を含まない部分を、日本語区間と英語区間の並びに分ける。空でない入力には必ず 1 つ以上の区間を返す
    private func segmentRun(_ input: String, leading: JapaneseContext) -> [Segment] {
        let chars = Array(input)
        let n = chars.count
        guard n > 0 else { return [] }

        // best[位置][直前の区間の種類] = (評価値, 区間)。同じ種類の区間は続けない
        struct Cell {
            var score: Double
            var segment: Segment
            var from: Int
            var previousKind: Segment.Kind?
        }
        var best: [[Segment.Kind: Cell]] = Array(repeating: [:], count: n + 1)

        func score(at pos: Int, excluding kind: Segment.Kind) -> (Double, Segment.Kind?)? {
            if pos == 0 { return (0, nil) }
            let other: Segment.Kind = kind == .japanese ? .english : .japanese
            guard let cell = best[pos][other] else { return nil }
            return (cell.score, other)
        }

        func relax(_ end: Int, _ start: Int, _ segment: Segment) {
            guard let (base, previous) = score(at: start, excluding: segment.kind) else { return }
            let total = base + segment.score
            if let current = best[end][segment.kind], current.score >= total { return }
            best[end][segment.kind] = Cell(score: total, segment: segment, from: start, previousKind: previous)
        }

        for start in 0..<n {
            let reachable = start == 0 || !best[start].isEmpty
            guard reachable else { continue }
            // この位置から始まる日本語区間を採れた終端。英語区間を締め出すのは、日本語区間を採れるときだけにする
            var japaneseEnds: Set<Int> = []
            for (end, kana) in table.readings(from: start, in: chars) {
                // 長音だけの区間は日本語として成り立たない（binge-watch の - など）
                if kana.allSatisfy({ $0 == "ー" }) { continue }
                // 日本語区間は日本語区間に続かないので、先頭でなければ直前は英語区間
                let context: JapaneseContext = start == 0 ? leading : .afterWord
                guard let reading = japaneseConverter.convert(kana: kana, context: context) else { continue }
                japaneseEnds.insert(end)
                let s = weights.japanese * reading.value - weights.japaneseSpanPenalty
                relax(end, start, Segment(kind: .japanese, source: String(chars[start..<end]), reading: kana, output: reading.text, score: s))
            }
            for end in (start + 1)...n {
                let source = String(chars[start..<end])
                // 1 つのかなになる綴り（ga to de no）、読める 2 文字以下の綴り（ie）、読めて英語の語表に無い綴り（utte deno）は、
                // 日本語として採れるなら英語にしない
                let readable = table.reading(of: source) != nil
                let preferJapanese = table.isSingleKana(source)
                    || (readable && (source.count <= Self.maxJapaneseFirstLength || !english.isWord(source)))
                if preferJapanese, japaneseEnds.contains(end) { continue }
                let s = weights.english * english.logProbability(source) - weights.englishSpanPenalty
                relax(end, start, Segment(kind: .english, source: source, reading: source, output: source, score: s))
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
        return segments.reversed()
    }
}
