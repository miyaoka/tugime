import Foundation

/// 2 つの精度の記録で、片方だけが正解した問題
public struct Comparison: Sendable {
    public enum Side: String, Sendable {
        case left, right
    }

    public struct Difference: Sendable {
        public var problem: Problem
        /// 正解した側
        public var passedBy: Side
        /// 打てなかった側は nil
        public var leftOutput: String?
        public var rightOutput: String?
    }

    /// 打てなかった問題の出力の欄に書く文字列
    static let untypedOutput = "（打てない）"

    public enum Failure: Error, CustomStringConvertible {
        /// 問題ファイルの SHA-256 が違う。違う版の問題どうしは比べない
        case differentProblems(left: [String: String], right: [String: String])
        /// 片方にしか無い id。同じ版なら起きないので、起きたら記録が壊れている
        case unmatched(String)
        /// 同じ id で読み・左の文脈・判定が違う。問題ファイルは同じでも、読み込みの規則が違う道具で取った記録である
        case differentProblem(left: Problem, right: Problem)
        /// 1 つの記録に同じ id が 2 つある。道具が書く記録では起きないので、手で書き換えた記録である
        case duplicateID(String)
        public var description: String {
            switch self {
            case .differentProblems(let left, let right): "2 つの記録の問題ファイルが違う版である: \(left) / \(right)"
            case .unmatched(let id): "片方の記録にしか無い問題: \(id)"
            case .differentProblem(let left, let right): "\(left.id) の問題が 2 つの記録で違う: \(left) / \(right)"
            case .duplicateID(let id): "記録に同じ問題が 2 つある: \(id)"
            }
        }
    }

    private static func byID(_ results: [AccuracyRecord.Result]) throws -> [String: AccuracyRecord.Result] {
        try Dictionary(results.map { ($0.problem.id, $0) }) { first, _ in throw Failure.duplicateID(first.problem.id) }
    }

    public var left: AccuracyRecord.Header
    public var right: AccuracyRecord.Header
    public var differences: [Difference]

    /// 不変条件: header.problemDigests が一致し、どちらの記録も id が重複せず、id の集合が一致し、同じ id の問題が一致する。並びは左の記録の順
    public init(left: AccuracyRecord, right: AccuracyRecord) throws {
        guard left.header.problemDigests == right.header.problemDigests else {
            throw Failure.differentProblems(left: left.header.problemDigests, right: right.header.problemDigests)
        }
        let rightByID = try Self.byID(right.results)
        let leftIDs = Set(try Self.byID(left.results).keys)
        if let extra = right.results.first(where: { !leftIDs.contains($0.problem.id) }) {
            throw Failure.unmatched(extra.problem.id)
        }
        self.left = left.header
        self.right = right.header
        differences = try left.results.compactMap { l in
            guard let r = rightByID[l.problem.id] else { throw Failure.unmatched(l.problem.id) }
            guard l.problem == r.problem else { throw Failure.differentProblem(left: l.problem, right: r.problem) }
            guard l.passes != r.passes else { return nil }
            return Difference(problem: l.problem, passedBy: l.passes ? .left : .right, leftOutput: l.typed?.output, rightOutput: r.typed?.output)
        }
    }

    /// 先頭に左右の方式。1 件 1 行のタブ区切り: id 正解した側（left|right） かな 左の文脈 左の出力 右の出力 判定。
    /// 打てなかった側の出力は untypedOutput。最後に「左だけ正解 n 件 / 右だけ正解 m 件」
    public var lines: [String] {
        let body = differences.map { d in
            let outputs = [d.leftOutput, d.rightOutput].map { $0 ?? Self.untypedOutput }
            return ([d.problem.id, d.passedBy.rawValue, d.problem.kana, d.problem.left] + outputs + [d.problem.check.kind]).joined(separator: "\t")
        }
        let leftOnly = differences.filter { $0.passedBy == .left }.count
        return ["left\t\(left.method)", "right\t\(right.method)"] + body + ["左だけ正解 \(leftOnly) 件 / 右だけ正解 \(differences.count - leftOnly) 件"]
    }
}
