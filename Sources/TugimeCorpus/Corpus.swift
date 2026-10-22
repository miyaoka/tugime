import Foundation

/// 例文集の 1 件。書式は例文集の先頭に書いてある
public struct CorpusExample: Sendable {
    public enum LoadError: Error, CustomStringConvertible {
        case malformedLine(String)
        public var description: String {
            switch self {
            case .malformedLine(let line): "例文集の行を読めない: \(line)"
            }
        }
    }

    public var input: String
    public var expected: String

    public static func load(path: String) throws -> [CorpusExample] {
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        return try lines.filter { !$0.hasPrefix("#") }.map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { throw LoadError.malformedLine(String(line)) }
            return CorpusExample(input: String(fields[0]), expected: String(fields[1]))
        }
    }
}
