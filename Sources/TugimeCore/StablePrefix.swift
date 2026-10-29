/// 打っている途中の表示のうち、打鍵を重ねても変わらなくなった先頭。確定して未確定の文字列から外すかを決める。
/// 確定した文字列は変換し直さない。外した打鍵は、後ろの打鍵ごとの区切りと変換の対象から外れる
public struct StablePrefix: Sendable {
    /// 先頭が同じ表示が、続けてこの打鍵の数だけ出たら確定してよい
    public var keystrokes: Int
    /// 未確定の打鍵がこの数に届くまでは確定しない
    public var minimumKeys: Int
    /// 確定した後ろに、未確定の打鍵を少なくともこの数だけ残す。打っている語の途中で確定しないようにする
    public var keptKeys: Int

    /// 偽なら確定しない
    public var commits = true

    /// 既定の設定。値は 1 打鍵の表示の時間と、打鍵の流れの表示で決める
    public static let standard = StablePrefix(keystrokes: 3, minimumKeys: 20, keptKeys: 10)
    /// 確定しない設定。前の部分の確定を入れる前の打鍵の流れと比べるのに使う
    public static let off: StablePrefix = {
        var stable = StablePrefix.standard
        stable.commits = false
        return stable
    }()

    /// 打鍵ごとの表示。新しいものが後ろ
    var recent: [String] = []

    public init(keystrokes: Int, minimumKeys: Int, keptKeys: Int) {
        self.keystrokes = keystrokes
        self.minimumKeys = minimumKeys
        self.keptKeys = keptKeys
    }

    /// `off` か、`<打鍵数>,<最小の打鍵数>,<残す打鍵数>` の形の設定。数はどれも 1 以上の整数でなければ nil
    public init?(spec: String) {
        if spec == Self.off.spec {
            self = Self.off
            return
        }
        let parts = spec.split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let keystrokes = parts[0], let minimum = parts[1], let kept = parts[2],
              [keystrokes, minimum, kept].allSatisfy({ $0 >= 1 })
        else { return nil }
        self.init(keystrokes: keystrokes, minimumKeys: minimum, keptKeys: kept)
    }

    /// init(spec:) が読む形
    public var spec: String { commits ? "\(keystrokes),\(minimumKeys),\(keptKeys)" : "off" }

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
        guard commits, keyCount >= minimumKeys, recent.count == keystrokes, var common = recent.first else { return nil }
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

/// 1 つの未確定の文字列を、入力メソッドと同じ手順で 1 打鍵ずつ打ち進め、画面を作る。tugime-cli と評価が使う
public struct LiveTyping {
    /// 1 打鍵の結果。typed はここまでの打鍵列の全体、screen は確定した文字列と未確定の表示をつないだ画面、
    /// committed はこの打鍵で確定した文字列、open はこの打鍵の後の未確定の打鍵の数、seconds は表示と確定にかかった時間
    public struct Step: Sendable {
        public var typed: String
        public var screen: String
        public var live: Segmenter.LiveDisplay
        public var committed: String?
        public var open: Int
        public var seconds: Double
    }

    var stable: StablePrefix
    var keys = ""
    var leading: Segmenter.Leading
    var typed = ""
    var committed = ""

    /// leading は打ち始めに入力欄のカーソルの前にあるもの
    public init(leading: Segmenter.Leading, stable: StablePrefix) {
        self.leading = leading
        self.stable = stable
    }

    public mutating func type(_ key: Character, segmenter: Segmenter) -> Step {
        typed.append(key)
        let clock = ContinuousClock()
        let start = clock.now
        let (live, done) = stable.append(String(key), to: &keys, leading: &leading, segmenter: segmenter)
        let elapsed = clock.now - start
        committed += done ?? ""
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Step(typed: typed, screen: committed + live.text, live: live, committed: done, open: keys.count, seconds: seconds)
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
