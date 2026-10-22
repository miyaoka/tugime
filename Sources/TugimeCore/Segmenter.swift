import Foundation

public struct Segment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
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
    private let table: RomajiTable
    private let english: EnglishModel
    private let japanese: any JapaneseConverting
    public var weights: SegmentWeights

    public init(table: RomajiTable, english: EnglishModel, japanese: any JapaneseConverting, weights: SegmentWeights = .standard) {
        self.table = table
        self.english = english
        self.japanese = japanese
        self.weights = weights
    }

    public func segment(_ input: String) -> [Segment] {
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
            for (end, kana) in table.readings(from: start, in: chars) {
                // 長音だけの区間は日本語として成り立たない（binge-watch の - など）
                if kana.allSatisfy({ $0 == "ー" }) { continue }
                // 日本語区間は日本語区間に続かないので、先頭でなければ直前は英語区間
                let context: JapaneseContext = start == 0 ? .start : .afterEnglish
                guard let reading = japanese.convert(kana: kana, context: context) else { continue }
                let s = weights.japanese * reading.value - weights.japaneseSpanPenalty
                relax(end, start, Segment(kind: .japanese, source: String(chars[start..<end]), reading: kana, output: reading.text, score: s))
            }
            for end in (start + 1)...n {
                let source = String(chars[start..<end])
                // 1 つのかなになる綴りは助詞などの日本語として読む。英語の語表に ga to de no があっても英語にしない
                if table.isSingleKana(source) { continue }
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
        return segments.reversed()
    }
}
