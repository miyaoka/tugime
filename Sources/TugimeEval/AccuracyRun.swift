import Foundation
import TugimeCore

/// 1 回の精度の実行の記録。ファイルには JSON Lines で書き、1 行目が header、2 行目以降が問題ごとの結果。
/// 記録は実行した事実だけを持ち、正誤と集計は記録から毎回計算する（記録に書くと、記録と食い違う写しになる）
public struct AccuracyRecord: Sendable, Codable {
    public struct Header: Sendable, Codable {
        /// ConversionMethod.spec
        public var method: String
        /// モデルのファイルの SHA-256。モデルを使わない方式は nil
        public var modelSHA256: String?
        /// 問題ファイルの名前ごとの SHA-256
        public var problemDigests: [String: String]
        /// 問題ファイルの名前ごとの、判定に写せず捨てた行の数
        public var droppedRows: [String: Int]
        public var startedAt: Date

        /// 方式のモデルの SHA-256 を計算して作る
        public init(method: ConversionMethod, problems: LoadedProblems, startedAt: Date) throws {
            self.method = method.spec
            modelSHA256 = try method.weight.map { try sha256(Data(contentsOf: $0, options: .alwaysMapped)) }
            problemDigests = problems.digests
            droppedRows = problems.dropped
            self.startedAt = startedAt
        }
    }

    public struct Result: Sendable, Codable {
        public var problem: Problem
        /// 対象の方式の表示の変換
        public var output: String
        /// 基準の方式（ConversionMethod.baseline）の表示の変換。対象が基準なら output と同じ
        public var baselineOutput: String
        /// 対象と基準の変換にかかった時間。対象が基準なら同じ値
        public var seconds: Double
        public var baselineSeconds: Double

        public var passes: Bool { problem.check.passes(output) }
        public var baselinePasses: Bool { problem.check.passes(baselineOutput) }
    }

    public var header: Header
    public var results: [Result]

    public enum ReadError: Error, CustomStringConvertible {
        case empty(URL)
        public var description: String {
            switch self {
            case .empty(let url): "記録が空: \(url.path)"
            }
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// JSON の文字列は改行を \n に書くので、1 件は必ず 1 行に収まる
    public func write(to url: URL) throws {
        let encoder = Self.encoder()
        let lines = try [encoder.encode(header)] + results.map { try encoder.encode($0) }
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> AccuracyRecord {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        guard let first = lines.first else { throw ReadError.empty(url) }
        let decoder = decoder()
        return try AccuracyRecord(
            header: decoder.decode(Header.self, from: Data(first.utf8)),
            results: lines.dropFirst().map { try decoder.decode(Result.self, from: Data($0.utf8)) }
        )
    }
}

/// 集まりごと・判定ごとの正解数。記録から作り、記録には書かない
public struct AccuracySummary: Sendable {
    public struct Row: Sendable {
        public var set: String
        /// nil はその集まりの全判定の合計
        public var kind: String?
        public var passed: Int
        public var baselinePassed: Int
        public var total: Int
    }

    public var rows: [Row]
    /// 対象の出力が基準と同じだった件数
    public var sameAsBaseline: Int
    public var total: Int

    /// 集まりは記録の順、判定は集まりの中で現れた順に並べる
    public init(_ results: [AccuracyRecord.Result]) {
        var keys: [(set: String, kind: String?)] = []
        var groups: [String: [AccuracyRecord.Result]] = [:]
        func add(_ set: String, _ kind: String?, _ result: AccuracyRecord.Result) {
            let name = "\(set)\t\(kind ?? "")"
            if groups[name] == nil { keys.append((set, kind)) }
            groups[name, default: []].append(result)
        }
        for result in results {
            add(result.problem.set, nil, result)
            add(result.problem.set, result.problem.check.kind, result)
        }
        rows = keys.map { key in
            let group = groups["\(key.set)\t\(key.kind ?? "")"]!
            return Row(
                set: key.set, kind: key.kind,
                passed: group.filter(\.passes).count, baselinePassed: group.filter(\.baselinePasses).count, total: group.count
            )
        }
        sameAsBaseline = results.filter { $0.output == $0.baselineOutput }.count
        total = results.count
    }

    /// 1 行目は列の名前。以降 1 行 1 集計のタブ区切り: 集まり 判定（all は全判定） 対象の正解数 基準の正解数 問題数 対象の正解率。
    /// 最後に、対象の出力が基準と同じだった件数
    public var lines: [String] {
        let header = ["集まり", "判定", "対象", "基準", "問題数", "対象の正解率"].joined(separator: "\t")
        let body = rows.map { row in
            let rate = String(format: "%.1f%%", Double(row.passed) / Double(row.total) * 100)
            return [row.set, row.kind ?? "all", String(row.passed), String(row.baselinePassed), String(row.total), rate].joined(separator: "\t")
        }
        return [header] + body + ["基準と同じ出力 \(sameAsBaseline) / \(total)"]
    }
}

/// 精度の実行。全問題を対象の方式と基準の方式の両方で変換し、記録を書き、集計を出し、モデルが効いているかを確かめる。
/// 確かめは記録を書いた後に同じ呼び出しの中で行うので、止まったときも何が出たかを記録から読める
public enum AccuracyRun {
    public enum Failure: Error, CustomStringConvertible {
        /// 表示の変換が nil を返した。JapaneseConverting.display の約束に反するので、正誤を付けずに止める
        case noOutput(Problem)
        /// モデルを使う方式の出力が、基準と全件で一致した
        case modelHadNoEffect(method: String, count: Int, record: URL)
        public var description: String {
            switch self {
            case .noOutput(let p): "\(p.id) の表示の変換が結果を返さない: \(p.kana)"
            case .modelHadNoEffect(let method, let count, let record):
                "\(method) の出力が基準の方式と \(count) 件すべてで一致した。モデルが効いていない。記録は \(record.path)"
            }
        }
    }

    /// 1 問ごとに進捗を `progress` に渡し（`[n/N] id 対象 ok|NG 基準 ok|NG 秒`）、集計の行を `report` に渡す。
    /// 時間の上限は watchdog が、変換器を作るところから記録を書き終えるまで見る。
    ///
    /// 不変条件:
    /// - 問題ごとに両方の変換器の endComposition を呼ぶ
    /// - 文脈は常に `.start`、left は Problem.left。精度は入力メソッドが表示する変換（display）で測る
    /// - 対象が基準なら変換器は 1 つだけ作り、baselineOutput = output とする
    /// - モデルを使う方式で全件の出力が基準と一致したら、記録と集計を出した後に modelHadNoEffect を投げる。
    ///   一致した件数ではなく全件で判定する。一致の件数は集計に出すが判定には使わない
    public static func run(
        problems: LoadedProblems,
        target: ConversionMethod,
        record url: URL,
        watchdog: Watchdog,
        progress: (String) -> Void,
        report: (String) -> Void
    ) throws {
        let startedAt = Date()
        let clock = ContinuousClock()
        watchdog.armLoad("モデルの SHA-256")
        let header = try AccuracyRecord.Header(method: target, problems: problems, startedAt: startedAt)
        let loadStart = clock.now
        watchdog.armLoad("読み込み \(target.spec)")
        let targetConverter = target.make()
        watchdog.armLoad("読み込み \(ConversionMethod.baseline.spec)")
        let baselineConverter = target == .baseline ? nil : ConversionMethod.baseline.make()
        progress("変換器の読み込み \(String(format: "%.2f", seconds(clock.now - loadStart)))s、問題 \(problems.problems.count) 件")

        var results: [AccuracyRecord.Result] = []
        for (n, problem) in problems.problems.enumerated() {
            watchdog.arm(item: problem.id)
            let (output, outputSeconds) = try display(problem, with: targetConverter, clock: clock)
            let (baselineOutput, baselineSeconds) = try baselineConverter.map { try display(problem, with: $0, clock: clock) } ?? (output, outputSeconds)
            let result = AccuracyRecord.Result(
                problem: problem, output: output, baselineOutput: baselineOutput, seconds: outputSeconds, baselineSeconds: baselineSeconds
            )
            results.append(result)
            let mark = { (ok: Bool) in ok ? "ok" : "NG" }
            progress("[\(n + 1)/\(problems.problems.count)] \(problem.id) 対象 \(mark(result.passes)) 基準 \(mark(result.baselinePasses)) \(String(format: "%.2f", outputSeconds))s")
        }

        watchdog.arm(item: "記録の書き出し")
        let record = AccuracyRecord(header: header, results: results)
        try record.write(to: url)
        watchdog.finish()

        AccuracySummary(results).lines.forEach(report)
        if modelHadNoEffect(results, target: target) {
            throw Failure.modelHadNoEffect(method: target.spec, count: results.count, record: url)
        }
    }

    /// モデルを使う方式で、全件の出力が基準と一致したか
    static func modelHadNoEffect(_ results: [AccuracyRecord.Result], target: ConversionMethod) -> Bool {
        target.weight != nil && results.allSatisfy { $0.output == $0.baselineOutput }
    }

    /// 1 問を表示の変換にかけ、出力と時間を返す。後の問題に覚えを持ち越さないよう endComposition まで呼ぶ
    private static func display(_ problem: Problem, with converter: any JapaneseConverting, clock: ContinuousClock) throws -> (String, Double) {
        let start = clock.now
        let shown = converter.display(kana: problem.kana, context: .start, left: problem.left)
        let elapsed = seconds(clock.now - start)
        converter.endComposition()
        guard let shown else { throw Failure.noOutput(problem) }
        return (shown.text, elapsed)
    }
}

/// Duration を秒の小数に
func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
