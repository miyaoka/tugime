import Foundation

/// 利用者が登録した語。1 行 1 語の `読み<TAB>表記` で、空行と # で始まる行は読まない。品詞と評価値は持たない。
/// 読みはひらがなと長音（ー）だけ。同じ読みに別の表記を何語でも置けるが、同じ読みと表記の組は 2 回書けない。
/// 1 行でも読めなければ全体を読まない（一部だけ入った辞書を作らない）
public struct UserDictionary: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        public let reading: String
        public let word: String
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case malformedLine(Int, String)
        case readingNotHiragana(Int, String)
        case duplicateEntry(Int, String)

        public var description: String {
            switch self {
            case .malformedLine(let n, let line): "利用者の辞書 \(n) 行目を読めない（読み、タブ、表記の順に書く）: \(line)"
            case .readingNotHiragana(let n, let reading): "利用者の辞書 \(n) 行目の読みに、ひらがなと ー 以外の文字がある: \(reading)"
            case .duplicateEntry(let n, let line): "利用者の辞書 \(n) 行目は前の行にもある: \(line)"
            }
        }
    }

    public static let empty = UserDictionary(entries: [])

    /// ファイルの行の順
    public let entries: [Entry]

    private init(entries: [Entry]) {
        self.entries = entries
    }

    public init(contents: String) throws {
        var entries: [Entry] = []
        var seen: Set<Entry> = []
        // CRLF の改行は 1 文字なので、"\n" ではなく改行の文字で分ける
        for (index, raw) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            // タブは区切りなので、前後の空白を除くときも残す
            let line = raw.trimmingCharacters(in: Self.padding)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else { throw ParseError.malformedLine(index + 1, line) }
            let entry = Entry(reading: String(fields[0]), word: String(fields[1]))
            guard entry.reading.unicodeScalars.allSatisfy(Self.isReadingScalar) else { throw ParseError.readingNotHiragana(index + 1, entry.reading) }
            guard seen.insert(entry).inserted else { throw ParseError.duplicateEntry(index + 1, line) }
            entries.append(entry)
        }
        self.entries = entries
    }

    private static let padding = CharacterSet.whitespaces.subtracting(CharacterSet(charactersIn: "\t"))

    /// ひらがな（ぁ〜ゖ）と長音
    private static func isReadingScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(scalar.value) || scalar == "ー"
    }
}
