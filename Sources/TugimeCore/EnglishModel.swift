import Foundation

/// 英語らしさを文字の 3-gram で測る。語表から起動時に数える。
/// 語表に無い綴り（github、cwd など）にも、英語の綴りとしての自然さで点を付けるために、語ではなく文字の並びを見る。
public struct EnglishModel: Sendable {
    public enum LoadError: Error, CustomStringConvertible {
        case missingResource
        public var description: String { "英語の語表がバンドルに無い" }
    }

    private static let begin: UInt8 = 0
    private static let end: UInt8 = 1
    private static let other: UInt8 = 2
    /// a-z を 3...28 に置く
    private static let symbolCount = 29
    /// 3-gram, 2-gram, 1-gram, 一様分布の混合比
    private static let weights: (Double, Double, Double, Double) = (0.6, 0.3, 0.09, 0.01)

    private var trigram: [Int32]
    private var bigram: [Int32]
    private var unigram: [Int32]
    private var bigramContext: [Int32]
    private var unigramContext: [Int32]
    private var total: Int32

    public init(words: some Sequence<Substring>) {
        let n = Self.symbolCount
        trigram = Array(repeating: 0, count: n * n * n)
        bigram = Array(repeating: 0, count: n * n)
        unigram = Array(repeating: 0, count: n)
        bigramContext = Array(repeating: 0, count: n * n)
        unigramContext = Array(repeating: 0, count: n)
        total = 0
        for word in words {
            let symbols = Self.symbols(word.lowercased())
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
    }

    public static func bundled() throws -> EnglishModel {
        guard let url = Bundle.module.url(forResource: "english-words", withExtension: "txt", subdirectory: "Resources") else {
            throw LoadError.missingResource
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return EnglishModel(words: text.split(separator: "\n"))
    }

    /// 1 語として見たときの自然対数の尤度。語頭と語末も含めて測る。
    public func logProbability(_ text: some StringProtocol) -> Double {
        let n = Self.symbolCount
        let symbols = Self.symbols(text.lowercased())
        var sum = 0.0
        for i in 2..<symbols.count {
            let (a, b, c) = (Int(symbols[i - 2]), Int(symbols[i - 1]), Int(symbols[i]))
            let p3 = ratio(trigram[(a * n + b) * n + c], bigramContext[a * n + b])
            let p2 = ratio(bigram[b * n + c], unigramContext[b])
            let p1 = ratio(unigram[c], total)
            let w = Self.weights
            sum += log(w.0 * p3 + w.1 * p2 + w.2 * p1 + w.3 / Double(n))
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
