import Foundation
import TugimeCore

let usage = """
    使い方（先頭に次を付けられる。--before <文字列> は入力欄のカーソルの前にその文字列がある状態として変換する。
    --method <方式> は変換の方式。\(ConversionMethod.forms)。既定は入力メソッドと同じ方式で、作業ディレクトリの .zenz/\(ConversionMethod.inputMethodModel) を読む。
    リポジトリの直下から実行し、モデルは bun scripts/fetch-genmai.ts で、システム辞書は bun scripts/fetch-dictionary.ts で用意する。
    システム辞書だけで変換するときは --method lattice。direct は表示の変換にモデルを使う。ほかのモデルは scripts/convert-hf-to-gguf.ts が出す。
    --dictionary <ファイル> は利用者の辞書（書式は入力メソッドと同じ）。渡さなければ利用者の語は無く、入力メソッドの辞書は読まない。
    --judge <数> は、英語にも日本語にも読める語の無い部分で、表示にして文として比べる区切りの候補の数。既定は \(Segmenter.defaultJudgedCandidates)。1 なら比べない。
    --stable <打鍵数>,<最小の打鍵数>,<残す打鍵数> は、--typing と --timing で、未確定の打鍵が最小の打鍵数に届いてから、表示の先頭が打鍵数だけ続けて変わらなければ、
    その先頭に収まり、後ろに残す打鍵数以上の打鍵が残る文節までを確定する設定。
    既定は入力メソッドと同じ \(StablePrefix.standard.spec)。--stable \(StablePrefix.off.spec) は確定しない。
    --explain・--lattice・--span の出力の表記は、区切りを採点したシステム辞書の変換で、表示の変換ではない）:
      tugime-cli <打鍵列>...                  --live と同じ文字列を、打鍵列の列を付けずに出す
      tugime-cli --live <打鍵列>...           文節の選択に入る前に表示し、Enter で確定する文字列を出す。
                                              入力メソッドが未確定の文字列の下に知らせを出す表示なら、打鍵列 と知らせを標準エラーに出す（既定の形も同じ）
      tugime-cli --typing <打鍵列>...         入力メソッドで 1 打鍵ずつ打ったときの表示を出す。1 打鍵 1 行のタブ区切りで
                                              ここまでの打鍵列 画面（確定した文字列と未確定の表示） 未確定の文字列の下に出る知らせ（出なければ空） この打鍵で確定した文字列（無ければ空）
      tugime-cli --timing <打鍵列>...         --typing と同じく 1 打鍵ずつ打ち、1 打鍵 1 行のタブ区切りで ここまでの打鍵列 画面 その打鍵の表示と確定にかかった ms この打鍵で確定した文字列 未確定の打鍵の数 を出す
      tugime-cli --stages <打鍵列>...         打鍵列ごとに、句読点で切った部分ごとの 4 段を出す。1 区切りの候補（区間と評価値）、
                                              2 辞書の変換の表記、3 モデルが比べた文の確からしさ（辞書の表記の文と、モデルが書いた表記の文の両方）と選んだ候補、
                                              最後に 4 画面の表記
      tugime-cli --explain <打鍵列>...        区切りと区間ごとの評価値を出す
      tugime-cli --lattice <打鍵列>...        区切りを決めた部分の採点で比べた区間の候補を出す。打鍵列ごとに == 打鍵列 の行の後、
                                              1 候補 1 行のタブ区切りで 始まり 終わり 直前の区間の種類 種類 打鍵 出力 点
      tugime-cli --clauses <打鍵列>...        文節ごとの候補を出す
      tugime-cli --resize <打鍵列> <操作>     文節を操作した結果を出す。操作は + で伸ばす、- で縮める、> と < で選ぶ文節を移す
      tugime-cli --whole <打鍵列>...          F6〜F10 の全体の変換を出す
      tugime-cli --span <英字|かな>...        英字は英語として、かなは日本語として評価値を出す
    """

let tag: [Segment.Kind: String] = [.japanese: "J", .english: "E", .punctuation: "P", .word: "U"]
let clauseTag: [Clause.Kind: String] = [.japanese: "J", .english: "E", .punctuation: "P", .word: "U", .whole: "W"]

/// 入力メソッドが未確定の文字列の下に知らせを出す表示なら、打鍵列と知らせを標準エラーに出す。標準出力の行の形は --live を読むもの（tugime-eval・図）が前提にする
func warnIfDiffers(_ live: Segmenter.LiveDisplay, input: String) {
    guard live.differsFromInput else { return }
    FileHandle.standardError.write(Data("\(input)\t\(Segmenter.LiveDisplay.warning)\n".utf8))
}

func describe(_ segments: [Segment]) -> String {
    segments.map { s in
        "\(tag[s.kind]!)[\(s.source)→\(s.output) \(String(format: "%.1f", s.score))]"
    }.joined(separator: " ")
}

/// 1 つの未確定の文字列の中で、入力メソッドと同じく 1 打鍵ずつ打つ。打ち終えたら未確定の文字列を終える
func typeThrough(_ input: String, segmenter: Segmenter, leading: Segmenter.Leading, stable: StablePrefix, each: (LiveTyping.Step) -> Void) {
    var typing = LiveTyping(leading: leading, stable: stable)
    for key in input {
        each(typing.type(key, segmenter: segmenter))
    }
    segmenter.endComposition()
}

var args = Array(CommandLine.arguments.dropFirst())
var leading = Segmenter.Leading.start
var stablePrefix = StablePrefix.standard
var methodSpec = ConversionMethod.inputMethod(modelDirectory: URL(fileURLWithPath: ".zenz")).spec
var dictionaryPath: String?
var judgedCandidates = Segmenter.defaultJudgedCandidates
while let option = args.first, ["--before", "--method", "--dictionary", "--judge", "--stable"].contains(option) {
    guard args.count >= 2 else {
        print(usage)
        exit(2)
    }
    switch option {
    case "--before":
        leading = Segmenter.Leading(field: args[1])
    case "--method":
        methodSpec = args[1]
    case "--judge":
        guard let count = Int(args[1]), count >= 1 else {
            print(usage)
            exit(2)
        }
        judgedCandidates = count
    case "--stable":
        guard let stable = StablePrefix(spec: args[1]) else {
            print(usage)
            exit(2)
        }
        stablePrefix = stable
    default:
        dictionaryPath = args[1]
    }
    args.removeFirst(2)
}
// 使い方は方式を作らずに出す。既定の方式はモデルのファイルを要するので、モデルが無くても使い方を読めるようにする
if args.first == nil || ["-h", "--help"].contains(args.first) {
    print(usage)
    exit(0)
}
do {
    let method = try ConversionMethod(spec: methodSpec)
    let system = try SystemDictionary(url: SystemDictionary.inRepository(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
    let dictionary = try dictionaryPath.map { UserDictionary(contents: try String(contentsOfFile: $0, encoding: .utf8)) } ?? .empty
    for line in dictionary.skipped {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
    /// 方式の区切りに利用者の語を入れたもの
    func makeSegmenter() throws -> Segmenter {
        let segmenter = try method.makeSegmenter(dictionary: system)
        segmenter.replaceUserDictionary(dictionary)
        segmenter.judgedCandidates = judgedCandidates
        return segmenter
    }
    switch args.first {
    case "--span":
        // 区間ごとの評価値を見る診断用。英語の綴りと、英語に続くかなを並べて渡す
        let english = try EnglishModel.bundled()
        let japanese = method.make(dictionary: system)
        try Segmenter(table: .bundled(), english: english, japanese: japanese).replaceUserDictionary(dictionary)
        for arg in args.dropFirst() {
            let isKana = arg.unicodeScalars.contains { $0.value > 0x3000 }
            if isKana {
                let start = japanese.convert(kana: arg, context: .start, ending: .open)
                let after = japanese.convert(kana: arg, context: .afterWord, ending: .open)
                print("J \(arg)\t先頭: \(start.map { "\($0.text) \($0.value)" } ?? "なし")\t英語の後: \(after.map { "\($0.text) \($0.value)" } ?? "なし")")
                continue
            }
            print("E \(arg)\t\(english.logProbability(arg))")
        }
    case "--whole":
        // F6〜F10 の全体の変換を並べる
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            print("\(input)\t" + CharacterForm.allCases.map { segmenter.convertWhole(input, to: $0, leading: leading) }.joined(separator: " / "))
        }
    case "--clauses":
        // IME の候補の窓に並ぶものを区間ごとに出す
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            print("== \(input)")
            for clause in segmenter.clauses(input, leading: leading) {
                print("\(clauseTag[clause.kind]!) \(clause.reading)\t\(clause.candidates.joined(separator: " / "))")
            }
        }
    case "--resize":
        guard args.count == 3 else {
            print(usage)
            exit(2)
        }
        let segmenter = try makeSegmenter()
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
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            let live = segmenter.liveDisplay(input, leading: leading)
            print("\(input)\t\(live.text)")
            warnIfDiffers(live, input: input)
        }
    case "--typing":
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            typeThrough(input, segmenter: segmenter, leading: leading, stable: stablePrefix) { step in
                print("\(step.typed)\t\(step.screen)\t\(step.live.differsFromInput ? Segmenter.LiveDisplay.warning : "")\t\(step.committed ?? "")")
            }
        }
    case "--timing":
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            typeThrough(input, segmenter: segmenter, leading: leading, stable: stablePrefix) { step in
                print("\(step.typed)\t\(step.screen)\t\(String(format: "%.1f", step.seconds * 1000))\t\(step.committed ?? "")\t\(step.open)")
            }
        }
    case "--stages":
        let segmenter = try makeSegmenter()
        func value(_ values: [Double]?, _ i: Int) -> String { values.map { String(format: "%.2f", $0[i]) } ?? "-" }
        for input in args.dropFirst() {
            print("== \(input)")
            for (part, judgement) in segmenter.judgements(input, leading: leading).enumerated() {
                for (i, candidate) in judgement.candidates.enumerated() {
                    let mark = i == judgement.chosen ? "*" : " "
                    print("  部分\(part + 1) 候補\(i + 1)\(mark)\t1 \(describe(candidate))\t2 \(judgement.dictionaryTexts[i]) (\(value(judgement.dictionaryValues, i)))\t3 \(judgement.shownTexts[i]) (\(value(judgement.shownValues, i)))")
                }
            }
            print("  4 \(segmenter.liveText(input, leading: leading))")
            segmenter.endComposition()
        }
    case "--explain":
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            let segments = segmenter.segment(input, leading: leading)
            print("\(segments.map(\.output).joined())\t\(describe(segments))")
        }
    case "--lattice":
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            print("== \(input)\t\(describe(segmenter.segment(input, leading: leading)))")
            for span in segmenter.candidates(input, leading: leading) {
                let after = span.after.map { tag[$0]! } ?? "-"
                let s = span.segment
                print([String(span.start), String(span.end), after, tag[s.kind]!, s.source, s.output, String(s.score)].joined(separator: "\t"))
            }
        }
    default:
        let segmenter = try makeSegmenter()
        for input in args {
            let live = segmenter.liveDisplay(input, leading: leading)
            print(live.text)
            warnIfDiffers(live, input: input)
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
