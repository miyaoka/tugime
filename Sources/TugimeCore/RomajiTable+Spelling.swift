import Foundation

/// 打鍵列の選び方。打鍵の少ない方、同じ長さなら打鍵列の辞書順で前の方
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
    /// 同じかなの綴りは表で上の行を使う。区切り方が複数あるとき（きゃ: kya / kixya、っちゃ: ttya / tcha）は、使った行のうち最も下の行が
    /// 上にある方を選び、それが同じなら打鍵列全体を prefersKeys で選ぶ。同じかなには常に同じ打鍵列を返す
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
                if let current = best[end], !prefers(candidate, over: current) { continue }
                best[end] = candidate
            }
        }
        guard let spelled = best[chars.count], reading(of: spelled.map(\.keys).joined()) == kana else { return nil }
        return spelled
    }

    /// 使った行のうち最も下の行が上にある方、同じなら prefersKeys。「っ」の重ね打ちの 1 文字は表の行ではないので数えない
    private func prefers(_ a: [SpelledKana], over b: [SpelledKana]) -> Bool {
        let lowest = { (spelled: [SpelledKana]) in spelled.compactMap { rank[$0.keys] }.max() ?? 0 }
        let (rankA, rankB) = (lowest(a), lowest(b))
        if rankA != rankB { return rankA < rankB }
        return prefersKeys(a.map(\.keys).joined(), over: b.map(\.keys).joined())
    }

    /// かなから綴りへの表。同じかなに綴りが複数あれば、表で上の行を選ぶ
    private var reverseEntries: [String: String] {
        var reverse: [String: String] = [:]
        for (key, value) in entries {
            if let current = reverse[value], rank[current]! < rank[key]! { continue }
            reverse[value] = key
        }
        return reverse
    }

    /// start から打てる 1 歩。表の 1 項目と、「っ」を次の項目の先頭の子音を重ねて打つもの。
    /// 「っ」は後ろに綴りが続くときだけ読むので、続く項目と組にして 1 歩にする。
    /// 「ん」は単独の n でも読めるが、既定の打ち方に合わせて表の項目（nn）で打つ
    private func steps(at start: Int, in chars: [Character], reverse: [String: String]) -> [[SpelledKana]] {
        var steps = entries(at: start, in: chars, reverse: reverse).map { [$0] }
        guard chars[start] == "っ" else { return steps }
        for entry in entries(at: start + 1, in: chars, reverse: reverse) {
            guard let first = entry.keys.first, sokuonLetters.contains(first) else { continue }
            steps.append([SpelledKana(kana: "っ", keys: String(first)), entry])
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

    /// 読み（ひらがなと、入力メソッドが打鍵から出す句読点・記号、打ったまま出る ASCII の文字）を打鍵列に逆にたどる。
    /// 句読点・記号・ASCII の文字の位置で読みを切り、かなの連なりは綴りの表（`RomajiTable.spelling(of:)`）でたどる。ASCII の文字はその文字を打つ。
    /// 空か、書けない文字を含めば nil。
    /// 句読点は直前が英語の区間なら打ったまま残り、英字の後のかなの綴りは英字と続けて読まれうるので、打鍵列を打った表示が読みと同じになるとは限らない
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
            let typedAsIs = ch.isASCII && !ch.isNewline
            guard let keys = typedAsIs ? String(ch) : symbolKeys[String(ch)] else {
                run.append(ch)
                continue
            }
            guard flush() else { return nil }
            spelled.append(SpelledKana(kana: String(ch), keys: keys))
        }
        return flush() ? spelled : nil
    }
}
