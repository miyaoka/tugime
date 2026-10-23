import Foundation
import TugimeCore
import TugimeCorpus

let usage = """
    使い方（先頭に次を付けられる。--after <english|japanese> はカーソルの前にその文字がある状態として変換する。
    --zenz <モデルのパス> は表示の変換に Zenzai を使う。scripts/fetch-zenz.sh が取得してパスを出す）:
      tugime-cli <打鍵列>...                  打鍵列を変換した結果を出す
      tugime-cli --live <打鍵列>...           文節の選択に入る前に表示し、Enter で確定する文字列を出す
      tugime-cli --explain <打鍵列>...        区切りと区間ごとの評価値を出す
      tugime-cli --clauses <打鍵列>...        文節ごとの候補を出す
      tugime-cli --resize <打鍵列> <操作>     文節を操作した結果を出す。操作は + で伸ばす、- で縮める、> と < で選ぶ文節を移す
      tugime-cli --whole <打鍵列>...          F6〜F10 の全体の変換を出す
      tugime-cli --span <英字|かな>...        英字は英語として、かなは日本語として評価値を出す
      tugime-cli --corpus <例文集.tsv>        例文集の全件を通し、一致件数を出す
      tugime-cli --tune <例文集.tsv>          重みを格子状に試し、近傍平均の高い順に出す
    """

func makeSegmenter(zenz: URL?) throws -> Segmenter {
    try Segmenter(table: .bundled(), english: .bundled(), japanese: AzooKeyConverter(zenzaiWeight: zenz))
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

/// 一致件数と外れた例文の区切りを出す
func runCorpus(_ examples: [CorpusExample], segmenter: Segmenter, leading: Segmenter.Leading) {
    var judged = 0
    var exact = 0
    for example in examples {
        let segments = segmenter.segment(example.input, leading: leading)
        let actual = segmenter.displayText(example.input, leading: leading)
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
}

func countJudged(_ examples: [CorpusExample], segmenter: Segmenter) -> Int {
    examples.filter { englishSources(segmenter.segment($0.input)) == asciiRuns($0.expected) }.count
}

/// 重みを格子状に試す。例文集の全件の日英判定を通す組だけを候補にする。
/// 1 点だけ通る組は例文集への合わせ込みなので、隣接する組との平均でならして順位を付ける
func tune(_ examples: [CorpusExample], segmenter: Segmenter) {
    let englishAxis = Array(stride(from: 0.8, through: 2.0, by: 0.1))
    let japanesePenaltyAxis = Array(stride(from: -4.0, through: 14.0, by: 1.0))
    let englishPenaltyAxis = Array(stride(from: -4.0, through: 12.0, by: 2.0))
    var counts: [[[Int]]] = []
    let started = Date()
    for english in englishAxis {
        print("english=\(String(format: "%.1f", english)) 開始 \(Int(Date().timeIntervalSince(started)))秒")
        var countPlane: [[Int]] = []
        for japanesePenalty in japanesePenaltyAxis {
            var countRow: [Int] = []
            for englishPenalty in englishPenaltyAxis {
                segmenter.weights = SegmentWeights(japanese: 1, english: english, japaneseSpanPenalty: japanesePenalty, englishSpanPenalty: englishPenalty)
                countRow.append(countJudged(examples, segmenter: segmenter))
            }
            countPlane.append(countRow)
        }
        counts.append(countPlane)
    }
    var ranked: [(smoothed: Double, count: Int, i: Int, j: Int, k: Int)] = []
    for i in englishAxis.indices {
        for j in japanesePenaltyAxis.indices {
            for k in englishPenaltyAxis.indices where counts[i][j][k] == examples.count {
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
    print("試した組 \(englishAxis.count * japanesePenaltyAxis.count * englishPenaltyAxis.count) 件、例文 \(examples.count) 件をすべて通す組 \(ranked.count) 件のうち、近傍平均の上位 15 件")
}

let leadings: [String: Segmenter.Leading] = ["english": .afterEnglish, "japanese": .afterJapanese]
var args = Array(CommandLine.arguments.dropFirst())
var leading = Segmenter.Leading.start
var zenz: URL?
while let option = args.first, ["--after", "--zenz"].contains(option) {
    guard args.count >= 2 else {
        print(usage)
        exit(2)
    }
    if option == "--after" {
        guard let value = leadings[args[1]] else {
            print(usage)
            exit(2)
        }
        leading = value
    } else {
        zenz = URL(fileURLWithPath: args[1])
    }
    args.removeFirst(2)
}
do {
    switch args.first {
    case nil, "-h", "--help":
        print(usage)
    case "--corpus", "--tune":
        guard args.count == 2 else {
            print(usage)
            exit(2)
        }
        let examples = try CorpusExample.load(path: args[1])
        let segmenter = try makeSegmenter(zenz: zenz)
        if args[0] == "--tune" {
            tune(examples, segmenter: segmenter)
            exit(0)
        }
        runCorpus(examples, segmenter: segmenter, leading: leading)
    case "--span":
        // 区間ごとの評価値を見る診断用。英語の綴りと、英語に続くかなを並べて渡す
        let english = try EnglishModel.bundled()
        let japanese = AzooKeyConverter(zenzaiWeight: zenz)
        for arg in args.dropFirst() {
            let isKana = arg.unicodeScalars.contains { $0.value > 0x3000 }
            if isKana {
                let start = japanese.convert(kana: arg, context: .start)
                let after = japanese.convert(kana: arg, context: .afterWord)
                print("J \(arg)\t先頭: \(start.map { "\($0.text) \($0.value)" } ?? "なし")\t英語の後: \(after.map { "\($0.text) \($0.value)" } ?? "なし")")
                continue
            }
            print("E \(arg)\t\(english.logProbability(arg))")
        }
    case "--whole":
        // F6〜F10 の全体の変換を並べる
        let segmenter = try makeSegmenter(zenz: zenz)
        for input in args.dropFirst() {
            print("\(input)\t" + CharacterForm.allCases.map { segmenter.convertWhole(input, to: $0, leading: leading) }.joined(separator: " / "))
        }
    case "--clauses":
        // IME の候補の窓に並ぶものを区間ごとに出す
        let segmenter = try makeSegmenter(zenz: zenz)
        for input in args.dropFirst() {
            print("== \(input)")
            for clause in segmenter.clauses(input, leading: leading) {
                print("\(tag[clause.kind]!) \(clause.reading)\t\(clause.candidates.joined(separator: " / "))")
            }
        }
    case "--resize":
        guard args.count == 3 else {
            print(usage)
            exit(2)
        }
        let segmenter = try makeSegmenter(zenz: zenz)
        var clauses = segmenter.clauses(args[1], leading: leading)
        var focus = 0
        func show(_ label: String) {
            let marked = clauses.enumerated().map { $0.offset == focus ? "[\($0.element.output)]" : $0.element.output }
            print("\(label)\t\(marked.joined(separator: " "))")
        }
        show("変換")
        for op in args[2] {
            switch op {
            case "+": clauses = segmenter.resize(clauses, at: focus, by: 1, leading: leading)
            case "-": clauses = segmenter.resize(clauses, at: focus, by: -1, leading: leading)
            case ">": focus = min(focus + 1, clauses.count - 1)
            case "<": focus = max(focus - 1, 0)
            default:
                print(usage)
                exit(2)
            }
            show(String(op))
        }
    case "--live":
        let segmenter = try makeSegmenter(zenz: zenz)
        for input in args.dropFirst() {
            print("\(input)\t\(segmenter.liveText(input, leading: leading))")
        }
    case "--explain":
        let segmenter = try makeSegmenter(zenz: zenz)
        for input in args.dropFirst() {
            let segments = segmenter.segment(input, leading: leading)
            print("\(segments.map(\.output).joined())\t\(describe(segments))")
        }
    default:
        let segmenter = try makeSegmenter(zenz: zenz)
        for input in args {
            print(segmenter.displayText(input, leading: leading))
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
