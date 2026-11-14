import Foundation

/// 利用者の綴りの表。打鍵列の区間をかなとして最後まで読めるかを判定する。
/// 打鍵をそのままかなにする（typedKana）ための、かなにするときだけ足して読む綴りも持つ
public struct RomajiTable: Sendable {
    /// file は読んだ表の名前（romaji.tsv など）
    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case malformedLine(file: String, Int, String)
        case unknownDirective(file: String, Int, String)
        case duplicateSpelling(file: String, Int, String)
        case directiveNotAllowed(file: String, Int, String)
        case missingResource(String)
        case noSpellings(file: String)

        public var description: String {
            switch self {
            case .malformedLine(let file, let n, let line): "\(file) \(n) 行目を読めない: \(line)"
            case .unknownDirective(let file, let n, let line): "\(file) \(n) 行目の指定が分からない: \(line)"
            case .duplicateSpelling(let file, let n, let key): "\(file) \(n) 行目の綴り \(key) は前の行にもある"
            case .directiveNotAllowed(let file, let n, let line): "\(file) \(n) 行目に @ の指定は書けない: \(line)"
            case .missingResource(let file): "既定の \(file) がバンドルに無い"
            case .noSpellings(let file): "\(file) に綴りが 1 行も無い"
            }
        }
    }

    static let tableFile = "romaji.tsv"
    static let typedKanaFile = "romaji-typed-kana.tsv"

    let entries: [String: String]
    /// 綴りごとの、表の中で何番目の行か。同じかなの綴りは上の行が既定の打ち方
    let rank: [String: Int]
    let maxKeyLength: Int
    let sokuonLetters: Set<Character>
    let nBeforeLetters: Set<Character>
    /// 打鍵をかなにする（typedKana）ときに読む綴り。綴りの表に、かなにするときだけ読む綴りを足したもの
    let typedKanaEntries: [String: String]
    let typedKanaMaxKeyLength: Int

    /// contents は綴りの表、typedKana は打鍵をかなにするときだけ足して読む綴り。typedKana は綴りの行だけを持ち、同じ綴りは contents を使う
    public init(contents: String, typedKana: String) throws {
        let table = try Self.parse(contents, file: Self.tableFile, allowsDirectives: true)
        // 綴りが無いと、打鍵を読む最長の綴りの長さが 0 になり、読む範囲を作れない
        guard !table.entries.isEmpty else { throw ParseError.noSpellings(file: Self.tableFile) }
        let extra = try Self.parse(typedKana, file: Self.typedKanaFile, allowsDirectives: false)
        self.entries = table.entries
        self.rank = table.rank
        self.maxKeyLength = table.entries.keys.map(\.count).max() ?? 0
        self.sokuonLetters = table.sokuon
        self.nBeforeLetters = table.nBefore
        self.typedKanaEntries = table.entries.merging(extra.entries) { own, _ in own }
        self.typedKanaMaxKeyLength = typedKanaEntries.keys.map(\.count).max() ?? 0
    }

    /// allowsDirectives が偽なら、@ で始まる行をエラーにする
    private static func parse(
        _ contents: String, file: String, allowsDirectives: Bool
    ) throws -> (entries: [String: String], rank: [String: Int], sokuon: Set<Character>, nBefore: Set<Character>) {
        var entries: [String: String] = [:]
        var rank: [String: Int] = [:]
        var sokuon: Set<Character> = []
        var nBefore: Set<Character> = []
        for (index, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count == 2 else { throw ParseError.malformedLine(file: file, index + 1, line) }
            let key = String(fields[0])
            let value = String(fields[1])
            guard key.hasPrefix("@") else {
                guard entries.updateValue(value, forKey: key) == nil else { throw ParseError.duplicateSpelling(file: file, index + 1, key) }
                rank[key] = rank.count
                continue
            }
            guard allowsDirectives else { throw ParseError.directiveNotAllowed(file: file, index + 1, line) }
            switch key {
            case "@sokuon": sokuon = Set(value)
            case "@n": nBefore = Set(value)
            default: throw ParseError.unknownDirective(file: file, index + 1, line)
            }
        }
        return (entries, rank, sokuon, nBefore)
    }

    public static func bundled() throws -> RomajiTable {
        try RomajiTable(contents: resource(tableFile), typedKana: resource(typedKanaFile))
    }

    private static func resource(_ file: String) throws -> String {
        let name = file as NSString
        guard let found = Bundle.module.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension, subdirectory: "Resources") else {
            throw ParseError.missingResource(file)
        }
        return try String(contentsOf: found, encoding: .utf8)
    }

    /// 打鍵を、Mozc が打鍵をかなにするのと同じく、前から順にかなにする。各位置で読める最も長い綴りを読み、綴りが無ければ、
    /// 同じ文字の重なり（@sokuon）の前の文字を っ と読む。どれでもない文字は打ったまま残す（github は ぎてゅb）。
    /// 綴りの表に加えて、かなにするときだけ読む綴り（単独の n を ん と読む行を含む）も読む。complete は打ったまま残した文字が無いか
    public func typedKana(of text: some StringProtocol) -> (kana: String, complete: Bool) {
        let chars = Array(text)
        var kana = ""
        var complete = true
        var pos = 0
        while pos < chars.count {
            if let (length, value) = longestTypedKana(at: pos, in: chars) {
                kana += value
                pos += length
                continue
            }
            if pos + 1 < chars.count, chars[pos] == chars[pos + 1], sokuonLetters.contains(chars[pos]) {
                kana += "っ"
            } else {
                kana.append(chars[pos])
                complete = false
            }
            pos += 1
        }
        return (kana, complete)
    }

    private func longestTypedKana(at pos: Int, in chars: [Character]) -> (length: Int, kana: String)? {
        for length in stride(from: min(typedKanaMaxKeyLength, chars.count - pos), through: 1, by: -1) {
            if let kana = typedKanaEntries[String(chars[pos..<(pos + length)])] { return (length, kana) }
        }
        return nil
    }

    /// start から読み始めて、読み切れる終端ごとのかなを返す。
    /// 「っ」と、@n の文字の前の単独の「ん」は後ろに綴りが続くときだけ読むので、それで終わる位置は終端にならない。
    /// input の末尾の単独の n は「ん」と読み、終端にする。
    public func readings(from start: Int, in input: [Character]) -> [(end: Int, kana: String)] {
        // 位置ごとに、そこまで読んだかなと、そこで区間を終えてよいか
        var reached: [Int: (kana: String, canEnd: Bool)] = [start: ("", false)]
        for pos in start..<input.count {
            guard let here = reached[pos] else { continue }
            for edge in edges(at: pos, in: input) {
                let kana = here.kana + edge.kana
                // 同じ位置に複数の読みで届いたときは、終端にできる読みを優先する
                if let existing = reached[edge.end], existing.canEnd || !edge.canEnd { continue }
                reached[edge.end] = (kana, edge.canEnd)
            }
        }
        return reached
            .filter { $0.key > start && $0.value.canEnd }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.kana) }
    }

    /// 綴り全体を最後まで読めればかなを返す
    public func reading(of text: some StringProtocol) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        return readings(from: 0, in: chars).first { $0.end == chars.count }?.kana
    }

    /// 読みが kana の綴りを、読みの先頭 kanaCount 文字に当たる綴りと残りの綴りに分ける。
    /// 1 つの綴りが複数のかなになる（kya → きゃ）ところの途中では切れないので nil
    public func split(_ text: String, kana whole: String, atKana kanaCount: Int) -> (head: String, tail: String)? {
        let chars = Array(text)
        let head = String(whole.prefix(kanaCount))
        let tail = String(whole.dropFirst(kanaCount))
        // 位置ごとに、そこまでで読めたかなのうち head の先頭に一致するもの
        var reached: [Int: Set<String>] = [0: [""]]
        for pos in 0..<chars.count {
            for kana in reached[pos] ?? [] {
                if kana == head, reading(of: String(chars[pos...])) == tail {
                    return (String(chars[..<pos]), String(chars[pos...]))
                }
                for edge in edges(at: pos, in: chars) where head.hasPrefix(kana + edge.kana) {
                    reached[edge.end, default: []].insert(kana + edge.kana)
                }
            }
        }
        return nil
    }

    /// 綴りの表の 1 項目だけで 1 つのかな（が・と・で・の など）になる綴りか。長音記号と、2 文字になる項目（the → てぇ、who → うぉ）は含めない
    public func isSingleKana(_ text: some StringProtocol) -> Bool {
        guard let kana = entries[String(text)] else { return false }
        return kana.count == 1 && kana != "ー"
    }

    private struct Edge {
        var end: Int
        var kana: String
        var canEnd: Bool
    }

    /// keys が次の打鍵で読みが変わる単独の n で終わるなら、その n を外した残りの読み（n だけなら空）。最後の n を外した残りが読め、
    /// その読みに「ん」を足すと全体の読みになるとき（kon、konnn、n）。最後の n が綴りの組の一部なら nil（konn、xn）。
    /// 入力の末尾の単独の n は、edges が「ん」と読んで終端にする綴りである
    func readingBeforePendingN(_ keys: some StringProtocol) -> String? {
        guard keys.last == "n", let whole = reading(of: keys) else { return nil }
        let rest = keys.dropLast()
        guard !rest.isEmpty else { return "" }
        guard let kana = reading(of: rest), kana + "ん" == whole else { return nil }
        return kana
    }

    private func edges(at pos: Int, in input: [Character]) -> [Edge] {
        var edges: [Edge] = []
        let next = pos + 1 < input.count ? input[pos + 1] : nil
        if let next, input[pos] == next, sokuonLetters.contains(next) {
            edges.append(Edge(end: pos + 1, kana: "っ", canEnd: false))
        }
        if input[pos] == "n", let next, nBeforeLetters.contains(next) {
            edges.append(Edge(end: pos + 1, kana: "ん", canEnd: false))
        }
        if input[pos] == "n", next == nil {
            edges.append(Edge(end: pos + 1, kana: "ん", canEnd: true))
        }
        for length in 1...maxKeyLength where pos + length <= input.count {
            if let kana = entries[String(input[pos..<(pos + length)])] {
                edges.append(Edge(end: pos + length, kana: kana, canEnd: true))
            }
        }
        return edges
    }
}
