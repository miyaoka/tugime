import Foundation
import TugimeCore

let usage = """
    使い方（先頭に次を付けられる。--before <文字列> は入力欄のカーソルの前にその文字列がある状態として変換する。
    --method <方式> は変換の方式。\(ConversionMethod.forms)。既定は入力メソッドと同じ方式で、作業ディレクトリの .zenz/\(ConversionMethod.inputMethodModel) を読む。
    リポジトリの直下から実行し、モデルは scripts/fetch-genmai.sh で用意する。azooKey だけで変換するときは --method azookey。
    zenzai と direct は表示の変換にモデルを使う。zenzai は azooKey がモデルを動かし、direct は tugime が動かす。ほかのモデルは scripts/convert-hf-to-gguf.sh が出す。
    --dictionary <ファイル> は利用者の辞書（書式は入力メソッドと同じ）。渡さなければ利用者の語は無く、入力メソッドの辞書は読まない。
    --explain・--lattice・--span の出力の表記は、区切りを採点した azooKey の変換で、表示の変換ではない）:
      tugime-cli <打鍵列>...                  --live と同じ文字列を、打鍵列の列を付けずに出す
      tugime-cli --live <打鍵列>...           文節の選択に入る前に表示し、Enter で確定する文字列を出す
      tugime-cli --typing <打鍵列>...         入力メソッドで 1 打鍵ずつ打ったときの表示を出す。1 打鍵 1 行のタブ区切りで
                                              ここまでの打鍵列 表示 未確定の文字列の下に出る知らせ（出なければ空）
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

func describe(_ segments: [Segment]) -> String {
    segments.map { s in
        "\(tag[s.kind]!)[\(s.source)→\(s.output) \(String(format: "%.1f", s.score))]"
    }.joined(separator: " ")
}

var args = Array(CommandLine.arguments.dropFirst())
var leading = Segmenter.Leading.start
var methodSpec = ConversionMethod.inputMethod(modelDirectory: URL(fileURLWithPath: ".zenz")).spec
var dictionaryPath: String?
while let option = args.first, ["--before", "--method", "--dictionary"].contains(option) {
    guard args.count >= 2 else {
        print(usage)
        exit(2)
    }
    switch option {
    case "--before":
        leading = Segmenter.Leading(field: args[1])
    case "--method":
        methodSpec = args[1]
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
    let dictionary = try dictionaryPath.map { UserDictionary(contents: try String(contentsOfFile: $0, encoding: .utf8)) } ?? .empty
    for line in dictionary.skipped {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
    /// 方式の区切りに利用者の語を入れたもの
    func makeSegmenter() throws -> Segmenter {
        let segmenter = try method.makeSegmenter()
        try segmenter.replaceUserDictionary(dictionary)
        return segmenter
    }
    switch args.first {
    case "--span":
        // 区間ごとの評価値を見る診断用。英語の綴りと、英語に続くかなを並べて渡す
        let english = try EnglishModel.bundled()
        let japanese = method.make()
        try Segmenter(table: .bundled(), english: english, japanese: japanese).replaceUserDictionary(dictionary)
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
            print("\(input)\t\(segmenter.liveText(input, leading: leading))")
        }
    case "--typing":
        // 入力メソッドと同じく、1 つの未確定の文字列の中で 1 打鍵ずつ伸ばし、打ち終えたら未確定の文字列を終える
        let segmenter = try makeSegmenter()
        for input in args.dropFirst() {
            for end in input.indices.dropFirst() + [input.endIndex] {
                let keys = String(input[..<end])
                let live = segmenter.liveDisplay(keys, leading: leading)
                print("\(keys)\t\(live.text)\t\(live.differsFromInput ? Segmenter.LiveDisplay.warning : "")")
            }
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
            print(segmenter.liveText(input, leading: leading))
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
