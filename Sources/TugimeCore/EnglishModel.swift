import Foundation

/// 英語の区間の確からしさを測る。日本語の文の中に英字のまま書かれる語は、その出現頻度で測る。
/// 頻度の表に無い綴り（claudecode、opencode など）は、未知の語として英語の綴りらしさ（文字の 3-gram）で測る。
/// 文字の 3-gram が長さごとに割り振る確率は、綴りらしさを数える語の長さの分布と合わないので、頻度の表に無い英字だけの綴りは、
/// 語の長さの分布より多く割り振っている長さ（短い綴りと、とても長い綴り）の分だけ下げる
public struct EnglishModel: Sendable {
    public enum LoadError: Error, CustomStringConvertible {
        case missingResource(String)
        case malformedLine(String, Int, String)
        public var description: String {
            switch self {
            case .missingResource(let name): "英語の語表がバンドルに無い: \(name)"
            case .malformedLine(let name, let line, let text): "英語の語表 \(name) の \(line) 行目を読めない: \(text)"
            }
        }
    }

    private static let begin: UInt8 = 0
    private static let end: UInt8 = 1
    private static let other: UInt8 = 2
    /// a-z を 3...28 に置く
    private static let symbolCount = 29
    /// 3-gram, 2-gram, 1-gram, 一様分布の混合比
    private static let weights: (Double, Double, Double, Double) = (0.6, 0.3, 0.09, 0.01)

    /// 英語の語として扱う、日本語の文章での頻度（Zipf 値）の下限。使いながら調整する
    static let minWordZipf = 2.0
    /// 表に無い語の項に掛ける重みの自然対数。表の語の項は出現確率そのもの（表全体の和は約 0.021）なので、
    /// この重みは確率ではなく、表の語に対する未知の語の比として働く。使いながら調整する
    static let unknownLogWeight = -1.0
    /// 長さの分布を数える最長の綴り。これより長い綴りは、まとめてこの長さとして数える
    private static let maxLength = 30
    /// 語の長さの分布を数えるときに、長さごとの語の数に足す値。語の一覧に無い長さにも確率を残す
    private static let lengthPseudoCount = 1.0

    /// 英語の語として扱う語（小文字）
    private var vocabulary: Set<String> = []
    /// 語ごとの、日本語の文章での出現確率の自然対数
    private var logFrequency: [String: Double] = [:]
    private var trigram: [Int32]
    private var bigram: [Int32]
    private var unigram: [Int32]
    private var bigramContext: [Int32]
    private var unigramContext: [Int32]
    private var total: Int32
    /// 長さごとの、表に無い英字だけの綴りに足す自然対数。綴りらしさがその長さの並び全体に割り振る確率が、
    /// 綴りらしさを数える語の長さの分布より多ければ、その比の分だけ下げる。少なければ 0
    private var lengthLogCorrection: [Double] = []

    /// spellings は綴りらしさを数える語、zipf は日本語の文章での語ごとの頻度
    public init(spellings: some Sequence<Substring>, zipf: [String: Double]) {
        let n = Self.symbolCount
        trigram = Array(repeating: 0, count: n * n * n)
        bigram = Array(repeating: 0, count: n * n)
        unigram = Array(repeating: 0, count: n)
        bigramContext = Array(repeating: 0, count: n * n)
        unigramContext = Array(repeating: 0, count: n)
        total = 0
        var lengthCounts = Array(repeating: Self.lengthPseudoCount, count: Self.maxLength + 1)
        for word in spellings {
            let symbols = Self.symbols(word.lowercased())
            lengthCounts[min(symbols.count - 3, Self.maxLength)] += 1
            for i in 2..<symbols.count {
                let (a, b, c) = (Int(symbols[i - 2]), Int(symbols[i - 1]), Int(symbols[i]))
                trigram[(a * n + b) * n + c] += 1
                bigramContext[a * n + b] += 1
                bigram[b * n + c] += 1
                unigramContext[b] += 1
                unigram[c] += 1
                total += 1
            }
        }
        for (word, value) in zipf {
            let key = word.lowercased()
            // Zipf 値は 10 億語あたりの出現回数の常用対数
            logFrequency[key] = (value - 9) * log(10)
            if value >= Self.minWordZipf { vocabulary.insert(key) }
        }
        lengthCounts[0] = 0
        let lengthTotal = lengthCounts.reduce(0, +)
        let mass = lengthMass()
        lengthLogCorrection = (0...Self.maxLength).map { length in
            guard length > 0, mass[length] > 0 else { return 0 }
            return min(0, log(lengthCounts[length] / lengthTotal) - log(mass[length]))
        }
    }

    /// 綴りらしさが長さごとの並び全体に割り振る確率。添字は長さで、maxLength はそれ以上の長さすべての和
    private func lengthMass() -> [Double] {
        let n = Self.symbolCount
        var mass = Array(repeating: 0.0, count: Self.maxLength + 1)
        var state = Array(repeating: 0.0, count: n * n)
        state[Int(Self.begin) * n + Int(Self.begin)] = 1
        for length in 1..<Self.maxLength {
            var next = Array(repeating: 0.0, count: n * n)
            for a in 0..<n {
                for b in 0..<n where state[a * n + b] > 0 {
                    for c in Int(Self.other)..<n {
                        next[b * n + c] += state[a * n + b] * probability(a, b, c)
                    }
                }
            }
            state = next
            for a in 0..<n {
                for b in 0..<n where state[a * n + b] > 0 {
                    mass[length] += state[a * n + b] * probability(a, b, Int(Self.end))
                }
            }
        }
        // 綴りらしさはすべての並びに割り振る確率の和が 1 なので、残りが maxLength 以上の長さの分になる
        mass[Self.maxLength] = 1 - mass.reduce(0, +)
        return mass
    }

    private func probability(_ a: Int, _ b: Int, _ c: Int) -> Double {
        let n = Self.symbolCount
        let p3 = ratio(trigram[(a * n + b) * n + c], bigramContext[a * n + b])
        let p2 = ratio(bigram[b * n + c], unigramContext[b])
        let p1 = ratio(unigram[c], total)
        let w = Self.weights
        return w.0 * p3 + w.1 * p2 + w.2 * p1 + w.3 / Double(n)
    }

    public static func bundled() throws -> EnglishModel {
        let spellings = try resource("english-words", "txt").split(separator: "\n")
        var zipf: [String: Double] = [:]
        for (index, line) in try resource("english-frequency", "tsv").split(separator: "\n").enumerated() {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let value = Double(fields[1]) else {
                throw LoadError.malformedLine("english-frequency.tsv", index + 1, String(line))
            }
            zipf[String(fields[0])] = value
        }
        return EnglishModel(spellings: spellings, zipf: zipf)
    }

    private static func resource(_ name: String, _ ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            throw LoadError.missingResource("\(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 日本語の文の中に英字のまま書かれる語か。大文字と小文字は区別しない
    public func isWord(_ text: some StringProtocol) -> Bool {
        vocabulary.contains(text.lowercased())
    }

    /// 1 語として見たときの自然対数の点。表の語としての出現確率と、重みを掛けた綴りらしさの和。
    /// 正規化した確率ではないが、区間ごとに足す定数は区切りの重みが吸収するので、比べ合いには効かない
    public func logProbability(_ text: some StringProtocol) -> Double {
        let lowered = text.lowercased()
        let unknown = Self.unknownLogWeight + spellingLogProbability(lowered)
        guard let known = logFrequency[lowered] else {
            // 頻度の表は英字だけの語でできているので、数字や記号を含む綴り（A4 など）は正しい綴りでも必ず表の外になる。補正を当てない
            let letters = lowered.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
            return letters ? unknown + lengthLogCorrection[min(lowered.count, Self.maxLength)] : unknown
        }
        let top = max(known, unknown)
        return top + log(exp(known - top) + exp(unknown - top))
    }

    /// 英語の綴りとしての自然対数の尤度。語頭と語末も含めて測る
    private func spellingLogProbability(_ lowered: String) -> Double {
        let symbols = Self.symbols(lowered)
        var sum = 0.0
        for i in 2..<symbols.count {
            sum += log(probability(Int(symbols[i - 2]), Int(symbols[i - 1]), Int(symbols[i])))
        }
        return sum
    }

    private func ratio(_ count: Int32, _ context: Int32) -> Double {
        context == 0 ? 0 : Double(count) / Double(context)
    }

    private static func symbols(_ text: String) -> [UInt8] {
        var result: [UInt8] = [begin, begin]
        for scalar in text.unicodeScalars {
            let v = scalar.value
            result.append((97...122).contains(v) ? UInt8(v - 97 + 3) : other)
        }
        result.append(end)
        return result
    }
}
