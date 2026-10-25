import Foundation

/// 利用者が登録した語。1 行 1 語の `打鍵<TAB>表記[<TAB>ja|en]` で、空行と # で始まる行は読まない。品詞と評価値は持たない。
/// 打鍵は、入力メソッドで打つとおりの綴り（空白を除く ASCII）。読みは利用者の綴りの表で決まるので、辞書には書かない。
/// 3 つ目の欄は、打鍵の区間を日本語区間と英語区間のどちらにするか（Entry.Kind）。登録は区切りと変換の判定より優先する。
/// 同じ打鍵に別の表記を何語でも置けるが、同じ打鍵と表記の組は 2 回書けない。
/// 1 行でも読めなければ全体を読まない（一部だけ入った辞書を作らない）
public struct UserDictionary: Sendable, Equatable {
    public struct Entry: Sendable, Hashable {
        /// 登録した打鍵の区間の種類
        public enum Kind: String, Sendable, CaseIterable {
            /// 日本語区間にする。打鍵をかなに読めれば、その読みの語としてかな漢字変換に入れる
            case japanese = "ja"
            /// 打鍵とちょうど一致する区間を、日本語として読めても英語区間にし、その表記にする
            case english = "en"
        }

        public let keys: String
        public let word: String
        /// 行に書いた種類。書かなければ nil
        public let declaredKind: Kind?

        /// 書かなければ、表記が ASCII だけなら英語、それ以外は日本語
        public var kind: Kind {
            declaredKind ?? (word.allSatisfy(\.isASCII) ? .english : .japanese)
        }
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case malformedLine(Int, String)
        case invalidKeys(Int, String)
        case unreachableKeys(Int, String)
        case unknownKind(Int, String)
        case duplicateEntry(Int, String)

        public var description: String {
            switch self {
            case .malformedLine(let n, let line): "tugime の辞書の \(n) 行目を読めない（打鍵、タブ、表記の順に書く）: \(line)"
            case .invalidKeys(let n, let keys): "tugime の辞書の \(n) 行目の打鍵は、英数字と記号（空白を除く ASCII）で書く: \(keys)"
            case .unreachableKeys(let n, let keys): "tugime の辞書の \(n) 行目の打鍵は、記号に変わる打鍵（zh / [ など）を含むか句読点で始まるので、打っても一致しない: \(keys)"
            case .unknownKind(let n, let kind): "tugime の辞書の \(n) 行目の 3 つ目の欄は、ja か en で書く: \(kind)"
            case .duplicateEntry(let n, let line): "tugime の辞書の \(n) 行目は前の行にもある: \(line)"
            }
        }
    }

    /// 読めた辞書を変換エンジンに入れられないとき（JapaneseConverting.replaceUserWords）
    public enum ImportError: Error, CustomStringConvertible, Equatable {
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
        var seen: Set<[String]> = []
        // CRLF の改行は 1 文字なので、"\n" ではなく改行の文字で分ける
        for (index, raw) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            // タブは区切りなので、前後の空白を除くときも残す
            let line = raw.trimmingCharacters(in: Self.padding)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(fields.count), !fields[0].isEmpty, !fields[1].isEmpty else { throw ParseError.malformedLine(index + 1, line) }
            var kind: Entry.Kind?
            if fields.count == 3 {
                guard let declared = Entry.Kind(rawValue: fields[2]) else { throw ParseError.unknownKind(index + 1, fields[2]) }
                kind = declared
            }
            let entry = Entry(keys: fields[0], word: fields[1], declaredKind: kind)
            guard entry.keys.unicodeScalars.allSatisfy(Self.isKeyScalar) else { throw ParseError.invalidKeys(index + 1, entry.keys) }
            guard Self.canBeTyped(entry.keys) else { throw ParseError.unreachableKeys(index + 1, entry.keys) }
            guard seen.insert([entry.keys, entry.word]).inserted else { throw ParseError.duplicateEntry(index + 1, line) }
            entries.append(entry)
        }
        self.entries = entries
    }

    /// 種類ごとの、打鍵ごとの表記。ファイルの行の順に持つ
    func words(of kind: Entry.Kind) -> [String: [String]] {
        Dictionary(grouping: entries.filter { $0.kind == kind }, by: \.keys).mapValues { $0.map(\.word) }
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
