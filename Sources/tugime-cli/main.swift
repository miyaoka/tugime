import Foundation
import TugimeCore

let usage = """
    使い方:
      tugime-cli <打鍵列>...                  打鍵列を変換した結果を出す
      tugime-cli --explain <打鍵列>...        区切りと区間ごとの評価値を出す
      tugime-cli --clauses <打鍵列>...        文節ごとの候補を出す
      tugime-cli --whole <打鍵列>...          F6〜F10 の全体の変換を出す
      tugime-cli --span <英字|かな>...        英字は英語として、かなは日本語として評価値を出す
      tugime-cli --corpus <例文集.tsv>        例文集の全件を通し、一致件数を出す
      tugime-cli --tune <例文集.tsv>          重みを格子状に試し、近傍平均の高い順に出す
    """

struct Example {
    var input: String
    var expected: String
    /// 出典が「完了条件」の例文。重みの探索では、これを落とす組を候補にしない
    var required: Bool
}

func makeSegmenter() throws -> Segmenter {
    try Segmenter(table: .bundled(), english: .bundled(), japanese: AzooKeyConverter())
}

let tag: [Segment.Kind: String] = [.japanese: "J", .english: "E", .punctuation: "P"]

func describe(_ segments: [Segment]) -> String {
    segments.map { s in
        "\(tag[s.kind]!)[\(s.source)→\(s.output) \(String(format: "%.1f", s.score))]"
    }.joined(separator: " ")
}

/// 期待値のうち ASCII の連なりを英語区間とみなす
func asciiRuns(_ text: String) -> [String] {
    var runs: [String] = []
    var current = ""
    for ch in text {
        if ch.isASCII {
            current.append(ch)
            continue
        }
        if !current.isEmpty { runs.append(current) }
        current = ""
    }
    if !current.isEmpty { runs.append(current) }
    return runs
}

func englishSources(_ segments: [Segment]) -> [String] {
    segments.filter { $0.kind == .english }.map(\.source)
}

func loadCorpus(path: String) throws -> [Example] {
    let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
    return try lines.filter { !$0.hasPrefix("#") }.map { line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2 else {
            throw NSError(domain: "tugime", code: 1, userInfo: [NSLocalizedDescriptionKey: "例文集の行を読めない: \(line)"])
        }
        let source = fields.count >= 3 ? String(fields[2]) : ""
        return Example(input: String(fields[0]), expected: String(fields[1]), required: source == "完了条件")
    }
}

func runCorpus(_ examples: [Example], segmenter: Segmenter) -> Bool {
    var judged = 0
    var exact = 0
    for example in examples {
        let segments = segmenter.segment(example.input)
        let actual = segments.map(\.output).joined()
        let judgeOK = englishSources(segments) == asciiRuns(example.expected)
        let exactOK = actual == example.expected
        if judgeOK { judged += 1 }
        if exactOK { exact += 1 }
        let mark = exactOK ? "ok   " : judgeOK ? "kanji" : "NG   "
        let detail = exactOK ? "" : "\t期待: \(example.expected)\t\(describe(segments))"
        print("\(mark) \(example.input)\t\(actual)\(detail)")
    }
    print("日英判定の一致 \(judged) / \(examples.count)")
    print("変換結果の一致 \(exact) / \(examples.count)")
    return judged == examples.count
}

func countJudged(_ examples: [Example], segmenter: Segmenter) -> Int {
    examples.filter { englishSources(segmenter.segment($0.input)) == asciiRuns($0.expected) }.count
}

/// 重みを格子状に試す。1 点だけ高い組は例文集への合わせ込みなので、隣接する組との平均でならして順位を付ける
func tune(_ examples: [Example], segmenter: Segmenter) {
    let englishAxis = Array(stride(from: 0.8, through: 2.0, by: 0.1))
    let japanesePenaltyAxis = Array(stride(from: -4.0, through: 14.0, by: 1.0))
    let englishPenaltyAxis = Array(stride(from: -4.0, through: 12.0, by: 2.0))
    let required = examples.filter(\.required)
    var counts: [[[Int]]] = []
    var requiredPassed: [[[Bool]]] = []
    let started = Date()
    for english in englishAxis {
        print("english=\(String(format: "%.1f", english)) 開始 \(Int(Date().timeIntervalSince(started)))秒")
        var countPlane: [[Int]] = []
        var requiredPlane: [[Bool]] = []
        for japanesePenalty in japanesePenaltyAxis {
            var countRow: [Int] = []
            var requiredRow: [Bool] = []
            for englishPenalty in englishPenaltyAxis {
                segmenter.weights = SegmentWeights(japanese: 1, english: english, japaneseSpanPenalty: japanesePenalty, englishSpanPenalty: englishPenalty)
                countRow.append(countJudged(examples, segmenter: segmenter))
                requiredRow.append(countJudged(required, segmenter: segmenter) == required.count)
            }
            countPlane.append(countRow)
            requiredPlane.append(requiredRow)
        }
        counts.append(countPlane)
        requiredPassed.append(requiredPlane)
    }
    var ranked: [(smoothed: Double, count: Int, i: Int, j: Int, k: Int)] = []
    for i in englishAxis.indices {
        for j in japanesePenaltyAxis.indices {
            for k in englishPenaltyAxis.indices where requiredPassed[i][j][k] {
                var sum = 0
                var n = 0
                for di in -1...1 {
                    for dj in -1...1 {
                        for dk in -1...1 {
                            let (a, b, c) = (i + di, j + dj, k + dk)
                            guard englishAxis.indices.contains(a), japanesePenaltyAxis.indices.contains(b), englishPenaltyAxis.indices.contains(c) else { continue }
                            sum += counts[a][b][c]
                            n += 1
                        }
                    }
                }
                ranked.append((Double(sum) / Double(n), counts[i][j][k], i, j, k))
            }
        }
    }
    for r in ranked.sorted(by: { $0.smoothed > $1.smoothed }).prefix(15) {
        print("近傍平均 \(String(format: "%.1f", r.smoothed))\t一致 \(r.count) / \(examples.count)\tenglish=\(String(format: "%.1f", englishAxis[r.i])) jPenalty=\(japanesePenaltyAxis[r.j]) ePenalty=\(englishPenaltyAxis[r.k])")
    }
    print("試した組 \(englishAxis.count * japanesePenaltyAxis.count * englishPenaltyAxis.count) 件、完了条件の例文 \(required.count) 件を通す組 \(ranked.count) 件のうち、近傍平均の上位 15 件")
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case nil, "-h", "--help":
        print(usage)
    case "--corpus", "--tune":
        guard args.count == 2 else {
            print(usage)
            exit(2)
        }
        let examples = try loadCorpus(path: args[1])
        let segmenter = try makeSegmenter()
        if args[0] == "--tune" {
            tune(examples, segmenter: segmenter)
            exit(0)
        }
        exit(runCorpus(examples, segmenter: segmenter) ? 0 : 1)
    case "--span":
        // 区間ごとの評価値を見る診断用。英語の綴りと、英語に続くかなを並べて渡す
        let english = try EnglishModel.bundled()
        let japanese = AzooKeyConverter()
        for arg in args.dropFirst() {
            let isKana = arg.unicodeScalars.contains { $0.value > 0x3000 }
            if isKana {
                let start = japanese.convert(kana: arg, context: .start)
                let after = japanese.convert(kana: arg, context: .afterEnglish)
                print("J \(arg)\t先頭: \(start.map { "\($0.text) \($0.value)" } ?? "なし")\t英語の後: \(after.map { "\($0.text) \($0.value)" } ?? "なし")")
                continue
            }
            print("E \(arg)\t\(english.logProbability(arg))")
        }
    case "--whole":
        // F6〜F10 の全体の変換を並べる
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            print("\(input)\t" + WholeConversion.allCases.map { segmenter.convertWhole(input, to: $0) }.joined(separator: " / "))
        }
    case "--clauses":
        // IME の候補の窓に並ぶものを区間ごとに出す
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            print("== \(input)")
            for clause in segmenter.clauses(input) {
                print("\(tag[clause.kind]!) \(clause.source)\t\(clause.candidates.joined(separator: " / "))")
            }
        }
    case "--explain":
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            let segments = segmenter.segment(input)
            print("\(segments.map(\.output).joined())\t\(describe(segments))")
        }
    default:
        let segmenter = try makeSegmenter()
        for input in args {
            print(segmenter.segment(input).map(\.output).joined())
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
