import Foundation

/// 候補の窓に足す記号。読みか記号から、その読みを持つ記号を引く。区切りの採点と表示の変換には使わない。
/// 表（symbol-candidates.tsv）は scripts/make-symbol-candidates.ts が Mozc の記号辞書から作る。1 行が「読み<TAB>記号<TAB>記号…」。
/// 読みの書き換え（全角の英数記号を半角に）は表を作るときに済ませてあるので、引くときは書き換えない
enum SymbolCandidates {
    static let file = "symbol-candidates.tsv"

    /// 読みごとの記号。並びは表の順
    static let byKey: [String: [String]] = {
        guard let url = Bundle.module.url(forResource: "symbol-candidates", withExtension: "tsv", subdirectory: "Resources"),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("\(file) をバンドルから読めない") }
        var table: [String: [String]] = [:]
        for (index, line) in contents.split(separator: "\n").enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty, table.updateValue(Array(fields.dropFirst()), forKey: fields[0]) == nil else {
                preconditionFailure("\(file) の \(index + 1) 行目を読めない: \(line)")
            }
        }
        return table
    }()

    /// key を読みとする記号のうち、丸括弧 1 文字でないもの。丸括弧は候補を選ぶと組の括弧も同じ形にする（Clause.pairingBrackets）ので、
    /// 丸括弧でない文節に足すと、選んだときに別の括弧と組になる
    static func symbols(for key: String) -> [String] {
        (byKey[key] ?? []).filter { !Segmenter.isRoundBracket($0) }
    }
}
