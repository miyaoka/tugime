import Foundation

/// 変更の前（before）と後（after）の精度の記録で、集まりごとの正解率と、片方だけが正解した問題
public struct Comparison: Sendable {
    public enum Side: String, Sendable {
        case before, after
    }

    public struct Difference: Sendable {
        public var problem: Problem
        /// 正解した側
        public var passedBy: Side
        /// 打てなかった側は nil
        public var beforeOutput: String?
        public var afterOutput: String?
    }

    /// 1 つの集まりの、前と後の正解数
    public struct Rate: Sendable, Equatable {
        public var set: String
        public var before: Int
        public var after: Int
        public var total: Int
    }

    /// 打てなかった問題の出力の欄に書く文字列
    static let untypedOutput = "（打てない）"

    public enum Failure: Error, CustomStringConvertible {
        /// 問題ファイルの SHA-256 が違う。違う版の問題どうしは比べない
        case differentProblems(before: [String: String], after: [String: String])
        /// 片方にしか無い id。同じ版なら起きないので、起きたら記録が壊れている
        case unmatched(String)
        /// 同じ id で読み・左の文脈・判定が違う。問題ファイルは同じでも、読み込みの規則が違う道具で取った記録である
        case differentProblem(before: Problem, after: Problem)
        /// 1 つの記録に同じ id が 2 つある。道具が書く記録では起きないので、手で書き換えた記録である
        case duplicateID(String)
        public var description: String {
            switch self {
            case .differentProblems(let before, let after): "2 つの記録の問題ファイルが違う版である: \(before) / \(after)"
            case .unmatched(let id): "片方の記録にしか無い問題: \(id)"
            case .differentProblem(let before, let after): "\(before.id) の問題が 2 つの記録で違う: \(before) / \(after)"
            case .duplicateID(let id): "記録に同じ問題が 2 つある: \(id)"
            }
        }
    }

    private static func byID(_ results: [AccuracyRecord.Result]) throws -> [String: AccuracyRecord.Result] {
        try Dictionary(results.map { ($0.problem.id, $0) }) { first, _ in throw Failure.duplicateID(first.problem.id) }
    }

    public var before: AccuracyRecord.Header
    public var after: AccuracyRecord.Header
    /// 集まりは前の記録に現れた順
    public var rates: [Rate]
    public var differences: [Difference]

    /// 不変条件: header.problemDigests が一致し、どちらの記録も id が重複せず、id の集合が一致し、同じ id の問題が一致する。並びは前の記録の順
    public init(before: AccuracyRecord, after: AccuracyRecord) throws {
        guard before.header.problemDigests == after.header.problemDigests else {
            throw Failure.differentProblems(before: before.header.problemDigests, after: after.header.problemDigests)
        }
        let afterByID = try Self.byID(after.results)
        let beforeIDs = Set(try Self.byID(before.results).keys)
        if let extra = after.results.first(where: { !beforeIDs.contains($0.problem.id) }) {
            throw Failure.unmatched(extra.problem.id)
        }
        self.before = before.header
        self.after = after.header
        let pairs = try before.results.map { b in
            guard let a = afterByID[b.problem.id] else { throw Failure.unmatched(b.problem.id) }
            guard b.problem == a.problem else { throw Failure.differentProblem(before: b.problem, after: a.problem) }
            return (before: b, after: a)
        }
        var sets: [String] = []
        var counts: [String: Rate] = [:]
        for pair in pairs {
            let set = pair.before.problem.set
            if counts[set] == nil {
                sets.append(set)
                counts[set] = Rate(set: set, before: 0, after: 0, total: 0)
            }
            counts[set]!.total += 1
            if pair.before.passes { counts[set]!.before += 1 }
            if pair.after.passes { counts[set]!.after += 1 }
        }
        rates = sets.map { counts[$0]! }
        differences = pairs.compactMap { pair in
            guard pair.before.passes != pair.after.passes else { return nil }
            return Difference(
                problem: pair.before.problem, passedBy: pair.before.passes ? .before : .after,
                beforeOutput: pair.before.typed?.output, afterOutput: pair.after.typed?.output
            )
        }
    }

    private var beforeOnly: Int { differences.filter { $0.passedBy == .before }.count }
    private var count: String { "before だけ正解 \(beforeOnly) 件 / after だけ正解 \(differences.count - beforeOnly) 件" }

    private static func percent(_ passed: Int, _ total: Int) -> String {
        String(format: "%.1f%%", Double(passed) / Double(total) * 100)
    }

    private func row(_ d: Difference) -> [String] {
        [d.problem.id, d.passedBy.rawValue, d.problem.kana, d.problem.left] + [d.beforeOutput, d.afterOutput].map { $0 ?? Self.untypedOutput } + [d.problem.check.kind]
    }

    /// 先頭に前と後の方式、続いて集まりごとの正解率（集まり before after 問題数）。
    /// 片方だけが正解した問題は 1 件 1 行のタブ区切り: id 正解した側（before|after） かな 入力の前の文脈 前の出力 後の出力 判定。
    /// 打てなかった側の出力は untypedOutput。最後に件数
    public var lines: [String] {
        let header = ["before\t\(before.method)", "after\t\(after.method)"]
        let rateLines = rates.map { [$0.set, Self.percent($0.before, $0.total), Self.percent($0.after, $0.total), String($0.total)].joined(separator: "\t") }
        return header + rateLines + differences.map { row($0).joined(separator: "\t") } + [count]
    }

    /// PR のコメントに置く Markdown。集まりごとの正解率の表、件数、片方だけが正解した問題の表（折りたたみ）
    public var markdown: [String] {
        let rateTable = ["| 集まり | before | after | 問題数 |", "| --- | --- | --- | --- |"]
            + rates.map { "| \($0.set) | \(Self.percent($0.before, $0.total)) | \(Self.percent($0.after, $0.total)) | \($0.total) |" }
        let problemTable = ["| 問題 | 正解した側 | 読み | 入力の前の文脈 | before | after | 判定 |", "| --- | --- | --- | --- | --- | --- | --- |"]
            + differences.map { "| " + row($0).map(Self.cell).joined(separator: " | ") + " |" }
        return rateTable + ["", count, "", "<details><summary>片方だけが正解した問題</summary>", ""] + problemTable + ["", "</details>"]
    }

    /// 表の 1 マス。縦棒と改行は表を壊すので置き換える
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
