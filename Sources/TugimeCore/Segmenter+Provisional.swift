import Foundation

/// 変換が届く前に、打った文字をすぐ見せるための表示
extension Segmenter {
    /// 打鍵列 keys の打っている途中の表示を、届いた変換 converted（届いた順）から作る。
    /// keys と同じ打鍵列の変換が届いていればそれを出す。届いていなければ、keys の先頭に当たる最新の変換から末尾の打ちかけの部分を外し、
    /// 外した打鍵とその後に打った打鍵の読みをつなぐ。打ちかけの部分を外せない変換は飛ばして、その前の変換を使う。どれも使えなければ keys 全体を読む。
    /// 後ろの読みが日本語区間の続きかは、変換の最後の区間で決める（打ちかけを外したときは後ろが 2 打鍵以上になり、単独の n にならない）
    public static func liveDisplay(
        of keys: String, converted: [(keys: String, display: LiveDisplay)], leading: Leading, table: RomajiTable
    ) -> LiveDisplay {
        if let same = converted.last(where: { $0.keys == keys }) { return same.display }
        for base in converted.reversed() where keys.hasPrefix(base.keys) {
            guard let split = splitPending(base.display.text, typed: base.keys) else { continue }
            let rest = keys.dropFirst(base.keys.count - split.pending)
            let read = provisionalText(
                of: rest, afterJapanese: afterJapanese(split.kept, leading: leading), inJapanese: base.display.endsInJapanese, table: table
            )
            return LiveDisplay(text: split.kept + read.text, differsFromInput: base.display.differsFromInput, endsInJapanese: read.endsInJapanese)
        }
        let read = provisionalText(of: keys, afterJapanese: afterJapanese("", leading: leading), inJapanese: false, table: table)
        return LiveDisplay(text: read.text, differsFromInput: false, endsInJapanese: read.endsInJapanese)
    }

    /// 表示 shown の後ろの句読点を日本語の記号にするか。区切りと同じく、未確定の文字列の中では直前が日本語か、先頭では入力欄の直前（leading）で決める
    static func afterJapanese(_ shown: String, leading: Leading) -> Bool {
        guard let last = shown.last else { return leading.continuation != .afterEnglish }
        return !last.isASCII
    }

    /// 打鍵列 keys の変換の表示 shown を、後ろに読みをつないでも崩れない部分と、末尾の打ちかけの打鍵の数に分ける。
    /// 打ちかけは、最後の母音より後ろの子音（表示に打ったまま出ている。読み終えた nn を除く）と、単独の n（表示では「ん」か、英語の区間なら打ったまま）。
    /// 打ちかけの打鍵は、後から打った打鍵とまとめて読み直す（g の後の i は「ぎ」、n の後の o は「の」）。
    /// 打ちかけの部分が表示の末尾にそのまま出ていなければ（ten の n が「点」に入っている）、分けられないので nil
    static func splitPending(_ shown: String, typed keys: String) -> (kept: String, pending: Int)? {
        let letters = keys.reversed().prefix { $0.isASCII && $0.isLetter }
        if letters.first == "n", letters.dropFirst().first != "n" {
            guard shown.hasSuffix("ん") || shown.hasSuffix("n") else { return nil }
            return (String(shown.dropLast()), 1)
        }
        var consonants = String(letters.prefix { !"aiueo".contains($0) }.reversed())
        // 母音の直後の nn は読み終えた「ん」
        if consonants.hasPrefix("nn") { consonants.removeFirst(2) }
        guard !consonants.isEmpty else { return (shown, 0) }
        return shown.hasSuffix(consonants) ? (String(shown.dropLast(consonants.count)), consonants.count) : nil
    }

    /// 変換が届く前に見せる keys の読み。区切りと同じく、記号の打鍵は記号にし、句読点は直前が日本語なら日本語の記号にする。
    /// それ以外は前から、読める所は最も長く読んでかなにし、読めない打鍵は打ったまま残す（kar → かr）。
    /// 区切りと同じく、日本語区間の頭（inJapanese が偽の位置）の末尾の n は な行 の途中なので打ったまま残す。
    /// 返す endsInJapanese は、読み終えた位置が日本語区間の途中か
    static func provisionalText(
        of keys: some StringProtocol, afterJapanese startsAfterJapanese: Bool, inJapanese startsInJapanese: Bool, table: RomajiTable
    ) -> (text: String, endsInJapanese: Bool) {
        let input = Array(keys)
        var text = ""
        var afterJapanese = startsAfterJapanese
        var inJapanese = startsInJapanese
        var position = 0
        while position < input.count {
            if let symbol = symbol(at: position, in: input) {
                text += symbol.mark
                afterJapanese = true
                inJapanese = false
                position += symbol.key.count
            } else if afterJapanese, let mark = punctuation[input[position]] {
                text += mark
                inJapanese = false
                position += 1
            } else if let longest = table.readings(from: position, in: input).last,
                      inJapanese || !RomajiTable.isLoneN(input[position...]) {
                text += longest.kana
                afterJapanese = true
                inJapanese = true
                position = longest.end
            } else {
                text.append(input[position])
                afterJapanese = false
                inJapanese = false
                position += 1
            }
        }
        return (text, inJapanese)
    }
}
