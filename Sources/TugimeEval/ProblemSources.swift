import CryptoKit
import Foundation

/// 問題ファイルを読んだ結果。問題と、記録に残す出自（ファイルの SHA-256 と、読み込みで捨てた行の数）
public struct LoadedProblems: Sendable {
    public var problems: [Problem]
    /// ファイル名ごとの SHA-256。比較はこれが一致する記録どうしだけを受け付ける
    public var digests: [String: String]
    /// ファイル名ごとの、判定に写せず捨てた行の数
    public var dropped: [String: Int]
}

/// 問題ファイルの置き場所。scripts/fetch-eval.sh が取得して SHA-256 を確かめ、このディレクトリのパスを出す。
/// ファイル名はスクリプトと同じものを使う。版はスクリプトが固定し、Swift 側は版を知らない
public struct ProblemFiles: Sendable {
    public var directory: URL

    /// 1 ファイルを読んだ問題と、捨てた行の数
    typealias Parsed = (problems: [Problem], dropped: Int)

    /// fetch-eval.sh が置くファイル名・集まりの名前・読む関数の表。集まりを足すときはスクリプトとこの表に 1 行ずつ足す
    static let sources: [(file: String, set: String, load: @Sendable (Data, String, String) throws -> Parsed)] = [
        ("ajimee-evaluation_items.json", AJIMEE.set, { (try AJIMEE.problems(from: $0, file: $1, set: $2), 0) }),
        ("mozc-oss.tsv", "mozc-oss", MozcRegression.problems(from:file:set:)),
        ("mozc-regression.tsv", "mozc-regression", MozcRegression.problems(from:file:set:)),
    ]

    public init(directory: URL) {
        self.directory = directory
    }

    /// すべての集まりを、表の順・ファイルの中の順に読む。ファイルが無い・読めない行があれば止める。
    /// SHA-256 は読んだのと同じバイト列から計算する。返す問題の id は全体で重複しない（重複すれば止める）
    public func load() throws -> LoadedProblems {
        var loaded = LoadedProblems(problems: [], digests: [:], dropped: [:])
        var seen: Set<String> = []
        for source in Self.sources {
            let url = directory.appendingPathComponent(source.file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ProblemLoadError.missingFile(url) }
            let data = try Data(contentsOf: url)
            let parsed = try source.load(data, source.file, source.set)
            for problem in parsed.problems where !seen.insert(problem.id).inserted {
                throw ProblemLoadError.duplicateID(problem.id)
            }
            loaded.problems += parsed.problems
            loaded.digests[source.file] = sha256(data)
            loaded.dropped[source.file] = parsed.dropped
        }
        return loaded
    }
}

/// バイト列の SHA-256 を 16 進の小文字で
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum ProblemLoadError: Error, CustomStringConvertible {
    case missingFile(URL)
    case malformed(file: String, line: Int, String)
    case duplicateID(String)
    public var description: String {
        switch self {
        case .missingFile(let url): "問題ファイルが無い: \(url.path)。scripts/fetch-eval.sh で取得する"
        case .malformed(let file, let line, let text): "\(file) の \(line) 番目を読めない: \(text)"
        case .duplicateID(let id): "問題の id が重複した: \(id)"
        }
    }
}

/// AJIMEE-Bench の JWTD_v2/v1/evaluation_items.json
enum AJIMEE {
    /// 集まりの名前。打鍵の計測もこの集まりから文を選ぶ
    static let set = "ajimee"

    /// JSON の 1 項目。使わない欄は読まない。index が無い項目は位置で代用せず止めるので、ここでは任意にして読む
    struct Item: Decodable {
        var index: String?
        var context_text: String
        var input: String
        var expected_output: [String]
    }

    /// id は `<set>:<index の欄の値>`。input はカタカナなのでひらがなにする。left は context_text
    static func problems(from data: Data, file: String, set: String) throws -> [Problem] {
        let items = try JSONDecoder().decode([Item].self, from: data)
        return try items.enumerated().map { position, item in
            guard let index = item.index else {
                throw ProblemLoadError.malformed(file: file, line: position + 1, "index が無い")
            }
            return Problem(id: "\(set):\(index)", set: set, kana: hiragana(item.input), left: item.context_text, check: .oneOf(item.expected_output))
        }
    }

    /// ひらがなと対になるカタカナ（ァ〜ヶ）
    private static let katakana: ClosedRange<UInt32> = 0x30A1...0x30F6
    /// カタカナからひらがなへの符号位置の差
    private static let katakanaOffset: UInt32 = 0x60

    /// カタカナを対のひらがなにし、それ以外（ー・、 など）は残す。
    /// Foundation の文字種の変換（hiraganaToKatakana の逆）は ー を前の母音に書き換える（てーま → てえま）ので使わない
    static func hiragana(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let shifted = katakana.contains(scalar.value) ? Unicode.Scalar(scalar.value - katakanaOffset)! : scalar
            scalars.append(shifted)
        }
        return String(scalars)
    }
}

/// Mozc の src/data/test/quality_regression_test の oss.tsv / regression.tsv
enum MozcRegression {
    /// command の言葉から判定を作る表。表に無い command（順位の付いた Conversion Expected 9、Prediction Expected など）の行は捨てて数える
    static let checks: [String: @Sendable (String) -> Check] = [
        "Conversion Expected": { .exact($0) },
        "Conversion Match": { .contains($0) },
        "Conversion Not Match": { .excludes($0) },
    ]

    /// 5 列目は許す順位。0（先頭の候補）だけが表示の変換 1 つで判定できる
    static let topRank = "0"

    /// 列: label・かなの key・value・command・順位（5 列目は無くてもよい）。id は `<set>:<ファイルの行番号>`。left は空。
    /// 順位が先頭の候補でない行は、command が表にあっても捨てて数える。
    /// # で始まる行と空行は飛ばし、捨てた数に入れない。列が 4 つ未満の行は malformed で止める
    static func problems(from data: Data, file: String, set: String) throws -> ProblemFiles.Parsed {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProblemLoadError.malformed(file: file, line: 0, "UTF-8 として読めない")
        }
        var problems: [Problem] = []
        var dropped = 0
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { throw ProblemLoadError.malformed(file: file, line: index + 1, String(line)) }
            // Mozc は空の列を飛ばして読むので、5 列目が無い行も空の行も順位 0 になる
            let rank = fields.count < 5 || fields[4].isEmpty ? topRank : fields[4]
            guard let check = checks[fields[3]], rank == topRank else {
                dropped += 1
                continue
            }
            problems.append(Problem(id: "\(set):\(index + 1)", set: set, kana: fields[1], left: "", check: check(fields[2])))
        }
        return (problems, dropped)
    }
}
