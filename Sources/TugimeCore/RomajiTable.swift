import Foundation

/// 利用者の綴りの表。打鍵列の区間をかなとして最後まで読めるかを判定する。
public struct RomajiTable: Sendable {
    public enum ParseError: Error, CustomStringConvertible {
        case malformedLine(Int, String)
        case unknownDirective(Int, String)
        case missingResource

        public var description: String {
            switch self {
            case .malformedLine(let n, let line): "綴りの表 \(n) 行目を読めない: \(line)"
            case .unknownDirective(let n, let line): "綴りの表 \(n) 行目の指定が分からない: \(line)"
            case .missingResource: "既定の綴りの表がバンドルに無い"
            }
        }
    }

    let entries: [String: String]
    let maxKeyLength: Int
    let sokuonLetters: Set<Character>
    let nBeforeLetters: Set<Character>

    public init(contents: String) throws {
        var entries: [String: String] = [:]
        var sokuon: Set<Character> = []
        var nBefore: Set<Character> = []
        for (index, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count == 2 else { throw ParseError.malformedLine(index + 1, line) }
            let key = String(fields[0])
            let value = String(fields[1])
            guard key.hasPrefix("@") else {
                entries[key] = value
                continue
            }
            switch key {
            case "@sokuon": sokuon = Set(value)
            case "@n": nBefore = Set(value)
            default: throw ParseError.unknownDirective(index + 1, line)
            }
        }
        self.entries = entries
        self.maxKeyLength = entries.keys.map(\.count).max() ?? 0
        self.sokuonLetters = sokuon
        self.nBeforeLetters = nBefore
    }

    public static func bundled() throws -> RomajiTable {
        guard let url = Bundle.module.url(forResource: "romaji", withExtension: "tsv", subdirectory: "Resources") else {
            throw ParseError.missingResource
        }
        return try RomajiTable(contents: String(contentsOf: url, encoding: .utf8))
    }

    /// start から読み始めて、読み切れる終端ごとのかなを返す。
    /// 「っ」と単独の「ん」は後ろに綴りが続くときだけ読むので、それで終わる位置は終端にならない。
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

    /// 綴りの表の 1 項目だけで 1 つのかな（が・と・で・の など）になる綴りか。長音記号は含めない
    public func isSingleKana(_ text: some StringProtocol) -> Bool {
        guard let kana = entries[String(text)] else { return false }
        return kana != "ー"
    }

    private struct Edge {
        var end: Int
        var kana: String
        var canEnd: Bool
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
        for length in 1...maxKeyLength where pos + length <= input.count {
            if let kana = entries[String(input[pos..<(pos + length)])] {
                edges.append(Edge(end: pos + length, kana: kana, canEnd: true))
            }
        }
        return edges
    }
}
