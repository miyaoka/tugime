import Foundation
import TugimeCore
import TugimeEngine
import TugimeEval

// 検証の道具。進捗は標準エラー、結果は標準出力と --out のファイル

let usage = """
    使い方:
      tugime-eval accuracy --method <方式> --problems <dir> --out <記録.jsonl>
          全問題の読みを綴りの表で打鍵列にし、問題の前の文脈を入力欄のカーソルの前の文字列として、方式と基準（lattice）で入力メソッドと同じく打ち、
          問題ごとの記録を書き、集まりごと・判定ごとの正解数を出す。綴りで書けない読みの問題は打たずに不正解とする。
          モデルを使う方式の出力が、打てた問題の全件で基準と一致したら、記録を書き、集計を出さずに終了コード 1
      tugime-eval compare [--markdown] <前の記録.jsonl> <後の記録.jsonl>
          集まりごとの正解率を前（before）と後（after）で並べ、片方だけが正解した問題を 1 件 1 行で出す。
          --markdown は同じ内容を、PR のコメントに置く Markdown の表で出す
      tugime-eval keystrokes --method <方式> --problems <dir> --out <最後の表示.tsv>
          AJIMEE-Bench の文を、問題の文脈と、上限の長さまで文をつないだ文脈の後に 1 打鍵ずつ打ち、1 打鍵の時間・読み込み時間・最大常駐量を出す。
          --out には 打鍵列 と最後の表示 をタブ区切りで書く（tugime-cli --live の出力と同じ形）
    方式: \(ConversionMethod.forms)
    問題の dir は scripts/fetch-eval.ts が出す。入力メソッドと同じモデルは scripts/fetch-genmai.ts が、ほかのモデルは scripts/convert-hf-to-gguf.ts が出す
    終了コード: 0 成功 / 1 モデルが効いていない / 2 使い方の誤り / 3 時間の上限を超えた / 4 それ以外のエラー（読めないモデルを含む）
    """

struct UsageError: Error, CustomStringConvertible {
    var message: String
    var description: String { "\(message)\n\(usage)" }
}

/// `--name value` の組を読む。知らない名前・値の欠け・重複・足りない名前は使い方の誤り
func options(_ args: ArraySlice<String>, required: Set<String>) throws -> [String: String] {
    var values: [String: String] = [:]
    var rest = args
    while let name = rest.popFirst() {
        guard required.contains(name) else { throw UsageError(message: "知らない引数: \(name)") }
        guard let value = rest.popFirst() else { throw UsageError(message: "\(name) の値が無い") }
        guard values.updateValue(value, forKey: name) == nil else { throw UsageError(message: "\(name) を 2 回渡した") }
    }
    if let missing = required.subtracting(values.keys).sorted().first { throw UsageError(message: "\(missing) が無い") }
    return values
}

func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

let problemOptions: Set<String> = ["--method", "--problems", "--out"]

/// リポジトリの直下から実行したときの、bun scripts/fetch-dictionary.ts が組み立てたシステム辞書
func repositoryDictionary() throws -> SystemDictionary {
    try SystemDictionary(url: SystemDictionary.inRepository(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
}

/// サブコマンドの表
let commands: [String: (ArraySlice<String>) throws -> Void] = [
    "accuracy": { args in
        // 上限はモデルの読み込みを含めてコマンドの始めから数える
        let watchdog = Watchdog(limits: .accuracy)
        let o = try options(args, required: problemOptions)
        let method = try ConversionMethod(spec: o["--method"]!)
        let problems = try ProblemFiles(directory: URL(fileURLWithPath: o["--problems"]!)).load()
        stderr("問題 \(problems.problems.count) 件。判定に写せず捨てた行 \(problems.dropped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "、"))")
        try AccuracyRun.run(
            problems: problems, target: method, dictionary: try repositoryDictionary(), generator: modelGenerator(weight:), record: URL(fileURLWithPath: o["--out"]!), watchdog: watchdog,
            progress: stderr, report: { print($0) }
        )
    },
    "compare": { args in
        let markdown = args.first == "--markdown"
        let records = markdown ? args.dropFirst() : args
        guard records.count == 2 else { throw UsageError(message: "記録を 2 つ渡す") }
        let before = try AccuracyRecord.read(from: URL(fileURLWithPath: records[records.startIndex]))
        let after = try AccuracyRecord.read(from: URL(fileURLWithPath: records[records.startIndex + 1]))
        let comparison = try Comparison(before: before, after: after)
        (markdown ? comparison.markdown : comparison.lines).forEach { print($0) }
    },
    "keystrokes": { args in
        let watchdog = Watchdog(limits: .keystroke)
        let o = try options(args, required: problemOptions)
        let method = try ConversionMethod(spec: o["--method"]!)
        let problems = try ProblemFiles(directory: URL(fileURLWithPath: o["--problems"]!)).load()
        let table = try RomajiTable.bundled()
        let selection = KeystrokeScript.select(from: problems.problems, table: table)
        for problem in selection.skipped {
            stderr("綴りで書けないので外す: \(problem.id) \(problem.kana)")
        }
        let report = try KeystrokeBench.run(selection: selection, method: method, dictionary: try repositoryDictionary(), generator: modelGenerator(weight:), watchdog: watchdog, progress: stderr)
        watchdog.arm(item: "書き出し")
        try (report.finalTextLines.joined(separator: "\n") + "\n").write(toFile: o["--out"]!, atomically: true, encoding: .utf8)
        watchdog.finish()
        report.lines.forEach { print($0) }
    },
]

/// エラーの種類から終了コードを引く表。表に無いエラーは 4
let exitCodes: [(matches: (Error) -> Bool, code: Int32)] = [
    ({ if case AccuracyRun.Failure.modelHadNoEffect = $0 { true } else { false } }, 1),
    ({ $0 is UsageError || $0 is ConversionMethod.ParseError }, 2),
]

let args = Array(CommandLine.arguments.dropFirst())
guard let name = args.first, let command = commands[name] else {
    print(usage)
    exit(2)
}
do {
    try command(args.dropFirst())
} catch {
    stderr("\(error)")
    exit(exitCodes.first { $0.matches(error) }?.code ?? 4)
}
