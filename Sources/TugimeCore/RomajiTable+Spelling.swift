import Foundation

/// 綴りが複数あるときの選び方。打鍵の少ない方、同じ長さなら打鍵列の辞書順で前の方
func prefersKeys(_ a: String, over b: String) -> Bool {
    a.count != b.count ? a.count < b.count : a < b
}

/// 読みの 1 文字分か 1 項目分の打鍵。何打鍵目でいくつの文字を打ち終えたかを数えるのに使う
public struct SpelledKana: Sendable, Equatable {
    /// 読みのうちこの打鍵が打つもの（き・きゃ・っ・ん・、 など）
    public var kana: String
    public var keys: String

    public init(kana: String, keys: String) {
        self.kana = kana
        self.keys = keys
    }
}

extension RomajiTable {
    /// かなを、利用者の綴りの表で打つ打鍵列に逆にたどる。表で書けないかなを含めば nil。
    ///
    /// 不変条件: 返した綴りを繋いだ打鍵列を `reading(of:)` で読むと kana に戻る。戻らなければ nil にする。
    /// 綴りが複数あるとき（ん: nn / n）は打鍵列全体を prefersKeys で選ぶ。同じかなには常に同じ打鍵列を返す
    public func spelling(of kana: String) -> [SpelledKana]? {
        let chars = Array(kana)
        guard !chars.isEmpty else { return nil }
        let reverse = reverseEntries
        // 位置ごとの、そこまでの最良の綴り
        var best: [[SpelledKana]?] = Array(repeating: nil, count: chars.count + 1)
        best[0] = []
        for start in 0..<chars.count {
            guard let here = best[start] else { continue }
            for step in steps(at: start, in: chars, reverse: reverse) {
                let candidate = here + step
                let end = start + step.map(\.kana.count).reduce(0, +)
                if let current = best[end], !prefersKeys(candidate.map(\.keys).joined(), over: current.map(\.keys).joined()) { continue }
                best[end] = candidate
            }
        }
        guard let spelled = best[chars.count], reading(of: spelled.map(\.keys).joined()) == kana else { return nil }
        return spelled
    }

    /// かなから綴りへの表。同じかなに綴りが複数あれば prefersKeys で選ぶ
    private var reverseEntries: [String: String] {
        var reverse: [String: String] = [:]
        for (key, value) in entries {
            if let current = reverse[value], !prefersKeys(key, over: current) { continue }
            reverse[value] = key
        }
        return reverse
    }

    /// start から打てる 1 歩。表の 1 項目、「っ」を次の項目の先頭の子音を重ねて打つもの、単独の n の「ん」に次の項目を続けたもの。
    /// 「っ」と単独の「ん」は後ろに綴りが続くときだけ読むので、続く項目と組にして 1 歩にする
    private func steps(at start: Int, in chars: [Character], reverse: [String: String]) -> [[SpelledKana]] {
        let entriesHere = entries(at: start, in: chars, reverse: reverse)
        var steps = entriesHere.map { [$0] }
        let next = entries(at: start + 1, in: chars, reverse: reverse)
        let leaders: [(kana: Character, letters: Set<Character>, keys: (Character) -> String)] = [
            ("っ", sokuonLetters, { String($0) }),
            ("ん", nBeforeLetters, { _ in "n" }),
        ]
        for leader in leaders where chars[start] == leader.kana {
            for entry in next {
                guard let first = entry.keys.first, leader.letters.contains(first) else { continue }
                steps.append([SpelledKana(kana: String(leader.kana), keys: leader.keys(first)), entry])
            }
        }
        return steps
    }

    /// start から始まるかなに当たる表の項目
    private func entries(at start: Int, in chars: [Character], reverse: [String: String]) -> [SpelledKana] {
        guard start < chars.count else { return [] }
        return (1...min(maxKanaLength, chars.count - start)).compactMap { length in
            let kana = String(chars[start..<(start + length)])
            return reverse[kana].map { SpelledKana(kana: kana, keys: $0) }
        }
    }

    /// 表の 1 項目が読むかなの最長
    private var maxKanaLength: Int {
        entries.values.map(\.count).max() ?? 0
    }
}

extension Segmenter {
    /// 句読点と記号を打鍵から逆にたどる表。同じ記号に打鍵が複数あれば prefersKeys で選ぶ（・ は / と z/ のうち /）
    static let symbolKeys: [String: String] = {
        var keys: [String: String] = [:]
        let all = punctuation.map { (String($0.key), $0.value) } + symbols.map { ($0.key, $0.value) }
        for (key, symbol) in all {
            if let current = keys[symbol], !prefersKeys(key, over: current) { continue }
            keys[symbol] = key
        }
        return keys
    }()

    /// 読み（ひらがなと、入力メソッドが打鍵から出す句読点・記号）を打鍵列に逆にたどる。
    /// 句読点・記号の位置で読みを切り、かなの連なりは綴りの表（`RomajiTable.spelling(of:)`）でたどる。空か、書けない文字を含めば nil。
    /// 句読点は直前が英語の区間なら打ったまま残るので、打鍵列を打った表示が読みと同じ記号になるとは限らない
    public static func spelling(of reading: String, table: RomajiTable) -> [SpelledKana]? {
        guard !reading.isEmpty else { return nil }
        var spelled: [SpelledKana] = []
        var run = ""
        func flush() -> Bool {
            guard !run.isEmpty else { return true }
            guard let kana = table.spelling(of: run) else { return false }
            spelled += kana
            run = ""
            return true
        }
        for ch in reading {
            guard let keys = symbolKeys[String(ch)] else {
                run.append(ch)
                continue
            }
            guard flush() else { return nil }
            spelled.append(SpelledKana(kana: String(ch), keys: keys))
        }
        return flush() ? spelled : nil
    }
}
