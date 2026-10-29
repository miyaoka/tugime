/// 打っている途中の表示のうち、打鍵を重ねても変わらなくなった先頭。確定して未確定の文字列から外すかを決める。
/// 確定した文字列は変換し直さない。外した打鍵は、後ろの打鍵ごとの区切りと変換の対象から外れる
public struct StablePrefix: Sendable {
    /// 先頭が同じ表示が、続けてこの打鍵の数だけ出たら確定してよい
    public var keystrokes: Int
    /// 未確定の打鍵がこの数に届くまでは確定しない
    public var minimumKeys: Int
    /// 確定した後ろに、未確定の打鍵を少なくともこの数だけ残す。打っている語の途中で確定しないようにする
    public var keptKeys: Int

    /// 既定の設定。値は 1 打鍵の表示の時間と、打鍵の流れの表示で決める
    public static let standard = StablePrefix(keystrokes: 3, minimumKeys: 20, keptKeys: 10)

    /// 打鍵ごとの表示。新しいものが後ろ
    var recent: [String] = []

    public init(keystrokes: Int, minimumKeys: Int, keptKeys: Int) {
        self.keystrokes = keystrokes
        self.minimumKeys = minimumKeys
        self.keptKeys = keptKeys
    }

    /// 打鍵 1 つ分の表示を覚える
    mutating func record(_ text: String) {
        recent.append(text)
        if recent.count > keystrokes { recent.removeFirst(recent.count - keystrokes) }
    }

    /// 打鍵を消したか、未確定の文字列を終えたか、先頭を確定したとき
    public mutating func reset() {
        recent = []
    }

    /// 確定してよい表示の先頭。未確定の打鍵が少ないか、覚えた表示が足りないか、変わらない先頭が無ければ nil
    func prefix(keyCount: Int) -> String? {
        guard keyCount >= minimumKeys, recent.count == keystrokes, var common = recent.first else { return nil }
        for text in recent.dropFirst() {
            common = String(zip(common, text).prefix { $0 == $1 }.map(\.0))
        }
        return common.isEmpty ? nil : common
    }

    /// 打鍵列 keys に key を足して表示し、表示の先頭が変わらなくなっていれば、その先頭に収まる文節までを確定する。
    /// 確定したら keys を残りの打鍵列に、leading を確定した文字列が続いたものにして、確定した文字列を返す。
    /// 入力メソッドと tugime-cli は、文字の打鍵をこれで足す
    public mutating func append(_ key: String, to keys: inout String, leading: inout Segmenter.Leading, segmenter: Segmenter) -> (display: Segmenter.LiveDisplay, committed: String?) {
        keys += key
        let display = segmenter.liveDisplay(keys, leading: leading)
        record(display.text)
        guard let prefix = prefix(keyCount: keys.count),
              let result = segmenter.commit(keys, leading: leading, within: prefix, keeping: keptKeys)
        else { return (display, nil) }
        keys = result.keys
        leading = result.leading
        reset()
        let rest = segmenter.liveDisplay(keys, leading: leading)
        record(rest.text)
        return (rest, result.text)
    }
}

extension Segmenter {
    /// 表示の先頭 prefix に収まる文節までを確定するときの、確定する文字列と残りの打鍵列と、残りの前にあるもの。残りの打鍵は kept 以上にする。
    /// 収まる文節が無いか、切る位置に当たる打鍵が決まらなければ nil。
    /// 確定するときは、残りの打鍵の語の決め方を、確定の前に決めたところから続けられるように引き継ぐ
    func commit(_ input: String, leading: Leading, within prefix: String, keeping kept: Int) -> (text: String, keys: String, leading: Leading)? {
        let clauses = shownClauses(input, leading: leading)
        var fits: [Int] = []
        var text = ""
        for (index, clause) in clauses.enumerated().dropLast() {
            text += clause.output
            guard prefix.hasPrefix(text) else { break }
            fits.append(index)
        }
        for index in fits.reversed() {
            guard let result = commit(clauses, through: index), result.keys.count >= kept else { continue }
            let after = Leading(field: leading.text + result.text)
            carryBeam(committedKeys: input.count - result.keys.count, rest: result.keys, after: after)
            return (result.text, result.keys, after)
        }
        return nil
    }

    /// 確定した打鍵が入力の最後の部分の中で終わるなら、その部分の語の割り当てから、確定した範囲にかかる語を外し、
    /// 位置を確定した打鍵の数だけ前にずらして、確定した後の入力 rest に引き継ぐ。最後の部分より前で終われば引き継がない
    private func carryBeam(committedKeys count: Int, rest: String, after: Leading) {
        guard let run = openRunBeam, count >= run.offset else {
            carriedBeam = nil
            return
        }
        let beam = run.beam.map { assignment in
            Dictionary(uniqueKeysWithValues: assignment.compactMap { word, english in
                word.start >= count ? (WordSpan(start: word.start - count, text: word.text), english) : nil
            })
        }
        carriedBeam = CarriedBeam(head: String(rest.prefix(max(0, run.upTo - count))), leading: after.japaneseContext, left: after.text, beam: beam)
    }
}
