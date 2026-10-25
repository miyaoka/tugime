import Foundation

/// 利用者が登録した語。1 行 1 語の `打鍵<TAB>表記` で、空行と # で始まる行は読まない。品詞と評価値は持たない。
/// 打鍵は、入力メソッドで打つとおりの綴り（空白を除く ASCII）。読みは利用者の綴りの表で決まるので、辞書には書かない。
/// 同じ打鍵に別の表記を何語でも置けるが、同じ打鍵と表記の組は 2 回書けない。
/// 1 行でも読めなければ全体を読まない（一部だけ入った辞書を作らない）
public struct UserDictionary: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        public let keys: String
        public let word: String
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case malformedLine(Int, String)
        case invalidKeys(Int, String)
        case unreachableKeys(Int, String)
        case duplicateEntry(Int, String)

        public var description: String {
            switch self {
            case .malformedLine(let n, let line): "tugime の辞書の \(n) 行目を読めない（打鍵、タブ、表記の順に書く）: \(line)"
            case .invalidKeys(let n, let keys): "tugime の辞書の \(n) 行目の打鍵は、英数字と記号（空白を除く ASCII）で書く: \(keys)"
            case .unreachableKeys(let n, let keys): "tugime の辞書の \(n) 行目の打鍵は、記号に変わる打鍵（zh / [ など）を含むか句読点で始まるので、打っても一致しない: \(keys)"
            case .duplicateEntry(let n, let line): "tugime の辞書の \(n) 行目は前の行にもある: \(line)"
            }
        }
    }

    /// 読めた辞書を変換エンジンに入れられないとき（JapaneseConverting.replaceUserWords）
    public enum ImportError: Error, CustomStringConvertible {
        case missingCharacterTable
        case unsupportedCharacter(reading: String)

        public var description: String {
            switch self {
            case .missingCharacterTable: "既定の辞書の文字の表（charID.chid）がバンドルに無い"
            case .unsupportedCharacter(let reading): "tugime の辞書の読み \(reading) に、変換エンジンが辞書で扱えない文字がある"
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
            let entry = Entry(keys: String(fields[0]), word: String(fields[1]))
            guard entry.keys.unicodeScalars.allSatisfy(Self.isKeyScalar) else { throw ParseError.invalidKeys(index + 1, entry.keys) }
            guard Self.canBeTyped(entry.keys) else { throw ParseError.unreachableKeys(index + 1, entry.keys) }
            guard seen.insert(entry).inserted else { throw ParseError.duplicateEntry(index + 1, line) }
            entries.append(entry)
        }
        self.entries = entries
    }

    /// かな漢字変換に入れる語。綴りの表で最後まで読め、英語の語でない打鍵だけを、そのかなの語にする。
    /// 英語の語でもある打鍵（node）を入れると、その読みが日本語の側に寄り、英語の語を割る（nodes が Node.js と s になる）ので、英語の区間の表記にだけ使う
    public func words(readingWith table: RomajiTable, english: EnglishModel) -> [UserWord] {
        entries.compactMap { entry in
            guard !english.isWord(entry.keys), let kana = table.reading(of: entry.keys), Segmenter.canBeJapanese(kana) else { return nil }
            return UserWord(reading: kana, word: entry.word)
        }
    }

    private static let padding = CharacterSet.whitespaces.subtracting(CharacterSet(charactersIn: "\t"))

    /// 打鍵が 1 つの区間の綴りになりうるか。区切りは記号の打鍵で入力を切り、句読点からは区間を始めない
    private static func canBeTyped(_ keys: String) -> Bool {
        let chars = Array(keys)
        guard let first = chars.first, Segmenter.punctuation[first] == nil else { return false }
        return chars.indices.allSatisfy { Segmenter.symbol(at: $0, in: chars) == nil }
    }

    /// 空白を除く ASCII の印字できる文字。入力メソッドが打鍵列に足す文字と同じ
    private static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x21...0x7E).contains(scalar.value)
    }
}

/// かな漢字変換に入れる利用者の語。読みは、登録した打鍵を利用者の綴りの表で読んだかな
public struct UserWord: Sendable, Hashable {
    public let reading: String
    public let word: String

    public init(reading: String, word: String) {
        self.reading = reading
        self.word = word
    }
}
