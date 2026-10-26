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
        public var outcome: Outcome

        /// 打てた問題の結果。打てなかった問題は nil
        public var typed: Typed? {
            guard case .typed(let typed) = outcome else { return nil }
            return typed
        }

        public var passes: Bool { typed.map { problem.check.passes($0.output) } ?? false }
        public var baselinePasses: Bool { typed.map { problem.check.passes($0.baselineOutput) } ?? false }
    }

    /// 問題を打てたか。打てなかったことも値として記録に書く（無いキーで表すと、欄の欠けた記録と見分けられない）
    public enum Outcome: Sendable, Codable {
        case typed(Typed)
        /// 読みが綴りで書けない文字を含む。利用者はその読みを打てないので、どちらの方式も不正解とする
        case untypable
    }

    public struct Typed: Sendable, Codable {
        /// 読みを綴りの表で逆にたどった打鍵列（Segmenter.spelling(of:table:)）
        public var keys: String
        /// 対象の方式で keys を打ったときに、Enter で確定する文字列
        public var output: String
        /// 基準の方式（ConversionMethod.baseline）で同じく打ったときの文字列。対象が基準なら output と同じ
        public var baselineOutput: String
        /// 対象と基準で打つのにかかった時間。対象が基準なら同じ値
        public var seconds: Double
        public var baselineSeconds: Double
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
    /// 綴りで書けない文字を含み、打てなかった問題の件数。正解数には入らず、問題数には入る
    public var untyped: Int
    /// 打てた問題のうち、対象の出力が基準と同じだった件数
    public var sameAsBaseline: Int
    /// 打てた問題のうち、出力が読みに対応づかなかった件数（ReadingAlignment が nil）。
    /// 漢字や英字の連なりの中の食い違いは数えないので、読みと違う出力の下限である。読みを英語の区間として打ったまま残した出力は、英字の連なりが読みを食うのでここに入らない
    public var unalignedTarget: Int
    public var unalignedBaseline: Int
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
        let typed = results.compactMap { result in result.typed.map { (problem: result.problem, typed: $0) } }
        untyped = results.count - typed.count
        sameAsBaseline = typed.filter { $0.typed.output == $0.typed.baselineOutput }.count
        unalignedTarget = typed.filter { ReadingAlignment(text: $0.typed.output, reading: $0.problem.kana) == nil }.count
        unalignedBaseline = typed.filter { ReadingAlignment(text: $0.typed.baselineOutput, reading: $0.problem.kana) == nil }.count
        total = results.count
    }

    /// 1 行目は列の名前。以降 1 行 1 集計のタブ区切り: 集まり 判定（all は全判定） 対象の正解数 基準の正解数 問題数 対象の正解率。
    /// 最後に、打てなかった問題の件数、対象の出力が基準と同じだった件数、読みとの対応を確かめられなかった出力の件数
    public var lines: [String] {
        let header = ["集まり", "判定", "対象", "基準", "問題数", "対象の正解率"].joined(separator: "\t")
        let body = rows.map { row in
            let rate = String(format: "%.1f%%", Double(row.passed) / Double(row.total) * 100)
            return [row.set, row.kind ?? "all", String(row.passed), String(row.baselinePassed), String(row.total), rate].joined(separator: "\t")
        }
        let typed = total - untyped
        return [header] + body + [
            "綴りで書けず打てなかった問題 \(untyped) / \(total)",
            "基準と同じ出力 \(sameAsBaseline) / \(typed)",
            "読みとの対応を確かめられなかった出力 対象 \(unalignedTarget) / 基準 \(unalignedBaseline) / \(typed)",
        ]
    }
}

/// 精度の実行。全問題の読みを対象の方式と基準の方式の両方で打ち、記録を書き、モデルが効いているかを確かめ、集計を出す。
/// 確かめは記録を書いた後に同じ呼び出しの中で行うので、止まったときも何が出たかを記録から読める
public enum AccuracyRun {
    public enum Failure: Error, CustomStringConvertible {
        /// 綴りで打てる問題が 1 つも無い。正解数を比べられないので、変換器を作る前に止める
        case noTypableProblems(count: Int)
        /// モデルを使う方式の出力が、基準と打てた問題の全件で一致した
        case modelHadNoEffect(method: String, count: Int, record: URL)
        public var description: String {
            switch self {
            case .noTypableProblems(let count): "綴りで打てる問題が無い（問題 \(count) 件）"
            case .modelHadNoEffect(let method, let count, let record):
                "\(method) の出力が基準の方式と \(count) 件すべてで一致した。モデルが効いていない。記録は \(record.path)"
            }
        }
    }

    /// 1 問ごとに進捗を `progress` に渡し（`[n/N] id 対象 ok|NG 基準 ok|NG 秒`、打てない問題は `[n/N] id 打てない`）、集計の行を `report` に渡す。
    /// 時間の上限は watchdog が、変換器を作るところから記録を書き終えるまで見る。
    ///
    /// 不変条件:
    /// - 精度は問題の読みを打ったときに確定する文字列で測る。読みを同梱の綴りの表で打鍵列に逆にたどり、
    ///   ConversionMethod.makeSegmenter(dictionary:) で作った区切りの liveText に渡す。対象と基準は同じシステム辞書を使う
    /// - Problem.left は、入力欄のカーソルより前の文字列として、入力メソッドと同じく Segmenter.Leading(field:) で読んで渡す
    /// - 問題ごとに両方の区切りの endComposition を呼ぶ
    /// - 打鍵列に逆にたどれない問題は打たずに outcome を untypable にし、どちらの方式も不正解とする。打てる問題が無ければ変換器を作る前に止める
    /// - 対象が基準なら区切りは 1 つだけ作り、baselineOutput = output とする
    /// - モデルを使う方式で打てた問題の全件の出力が基準と一致したら、記録を書いた後、集計を出す前に modelHadNoEffect を投げる。
    ///   一致した件数ではなく全件で判定する。一致の件数は集計に出すが判定には使わない
    public static func run(
        problems: LoadedProblems,
        target: ConversionMethod,
        dictionary: SystemDictionary,
        record url: URL,
        watchdog: Watchdog,
        progress: (String) -> Void,
        report: (String) -> Void
    ) throws {
        let startedAt = Date()
        let clock = ContinuousClock()
        let table = try RomajiTable.bundled()
        let keys = problems.problems.map { Segmenter.spelling(of: $0.kana, table: table)?.map(\.keys).joined() }
        guard keys.contains(where: { $0 != nil }) else { throw Failure.noTypableProblems(count: problems.problems.count) }
        watchdog.armLoad("モデルの SHA-256")
        let header = try AccuracyRecord.Header(method: target, problems: problems, startedAt: startedAt)
        let loadStart = clock.now
        watchdog.armLoad("読み込み \(target.spec)")
        let targetSegmenter = try target.makeSegmenter(dictionary: dictionary)
        watchdog.armLoad("読み込み \(ConversionMethod.baseline.spec)")
        let baselineSegmenter = target == .baseline ? nil : try ConversionMethod.baseline.makeSegmenter(dictionary: dictionary)
        progress("変換器の読み込み \(String(format: "%.2f", seconds(clock.now - loadStart)))s、問題 \(problems.problems.count) 件")

        var results: [AccuracyRecord.Result] = []
        for (n, (problem, keys)) in zip(problems.problems, keys).enumerated() {
            watchdog.arm(item: problem.id)
            let count = "[\(n + 1)/\(problems.problems.count)] \(problem.id)"
            guard let keys else {
                results.append(AccuracyRecord.Result(problem: problem, outcome: .untypable))
                progress("\(count) 打てない")
                continue
            }
            let leading = Segmenter.Leading(field: problem.left)
            let (output, outputSeconds) = type(keys, leading: leading, with: targetSegmenter, clock: clock)
            let (baselineOutput, baselineSeconds) = baselineSegmenter.map { type(keys, leading: leading, with: $0, clock: clock) } ?? (output, outputSeconds)
            let result = AccuracyRecord.Result(problem: problem, outcome: .typed(AccuracyRecord.Typed(
                keys: keys, output: output, baselineOutput: baselineOutput, seconds: outputSeconds, baselineSeconds: baselineSeconds
            )))
            results.append(result)
            let mark = { (ok: Bool) in ok ? "ok" : "NG" }
            progress("\(count) 対象 \(mark(result.passes)) 基準 \(mark(result.baselinePasses)) \(String(format: "%.2f", outputSeconds))s")
        }

        watchdog.arm(item: "記録の書き出し")
        let record = AccuracyRecord(header: header, results: results)
        try record.write(to: url)
        watchdog.finish()

        if modelHadNoEffect(results, target: target) {
            throw Failure.modelHadNoEffect(method: target.spec, count: results.count { $0.typed != nil }, record: url)
        }
        AccuracySummary(results).lines.forEach(report)
    }

    /// モデルを使う方式で、打てた問題の全件の出力が基準と一致したか
    static func modelHadNoEffect(_ results: [AccuracyRecord.Result], target: ConversionMethod) -> Bool {
        target.weight != nil && results.compactMap(\.typed).allSatisfy { $0.output == $0.baselineOutput }
    }

    /// 打鍵列を打ち、Enter で確定する文字列と時間を返す。後の問題に覚えを持ち越さないよう endComposition まで呼ぶ
    private static func type(_ keys: String, leading: Segmenter.Leading, with segmenter: Segmenter, clock: ContinuousClock) -> (String, Double) {
        let start = clock.now
        let text = segmenter.liveText(keys, leading: leading)
        let elapsed = seconds(clock.now - start)
        segmenter.endComposition()
        return (text, elapsed)
    }
}

/// Duration を秒の小数に
func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
