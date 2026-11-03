import Foundation

/// 変換が届く前に、打った文字をすぐ見せるための表示
extension Segmenter {
    /// 打鍵列 keys の打っている途中の表示を、届いた変換 converted（届いた順）から作る。
    /// keys と同じ打鍵列の変換が届いていればそれを出す。届いていなければ、keys の先頭に当たる最新の変換から末尾の打ちかけの部分を外し、
    /// 外した打鍵とその後に打った打鍵の読みをつなぐ。打ちかけの部分を外せない変換は飛ばして、その前の変換を使う。どれも使えなければ keys 全体を読む
    public static func liveDisplay(
        of keys: String, converted: [(keys: String, display: LiveDisplay)], leading: Leading, table: RomajiTable
    ) -> LiveDisplay {
        if let same = converted.last(where: { $0.keys == keys }) { return same.display }
        for base in converted.reversed() where keys.hasPrefix(base.keys) {
            guard let split = splitPending(base.display.text, typed: base.keys, table: table) else { continue }
            let rest = keys.dropFirst(base.keys.count - split.pending)
            let preceding = split.kept.last ?? leading.text.last
            let text = split.kept + provisionalText(of: rest, afterJapanese: afterJapanese(split.kept, leading: leading), preceding: preceding, table: table)
            return LiveDisplay(text: text, differsFromInput: base.display.differsFromInput)
        }
        let text = provisionalText(of: keys, afterJapanese: afterJapanese("", leading: leading), preceding: leading.text.last, table: table)
        return LiveDisplay(text: text, differsFromInput: false)
    }

    /// 表示 shown の後ろの句読点を日本語の記号にするか。区切りと同じく、未確定の文字列の中では直前が日本語か、先頭では入力欄の直前（leading）で決める。
    /// 数字で終わるなら、区切りと同じく数字の前の文字の側に付く（Continuation）
    static func afterJapanese(_ shown: String, leading: Leading) -> Bool {
        if shown.last.map(isDigit) == true { return Continuation(after: leading.text + shown) != .afterEnglish }
        guard let last = shown.last else { return leading.continuation != .afterEnglish }
        return !last.isASCII
    }

    /// 打鍵列 keys の変換の表示 shown を、後ろに読みをつないでも崩れない部分と、末尾の打ちかけの打鍵の数に分ける。
    /// 打ちかけは、最後の母音より後ろの子音（表示に打ったまま出ている。読み終えた nn を除く）と、表示に打ったまま出ている末尾の単独の n。
    /// 末尾の n が単独かは、打鍵の末尾の英字のうち綴りの表で読める最も長い部分を、表の読みで決める（RomajiTable.readingBeforePendingN）。
    /// 読み終えた nn の n は単独ではない（英語として登録した konn の Konn）。xnn の最後の n は単独
    /// 打ちかけの打鍵は、後から打った打鍵とまとめて読み直す（g の後の i は「ぎ」、n の後の o は「の」）。
    /// 打ちかけの部分が表示の末尾にそのまま出ていなければ（xn の n が「ん」に入っている）、分けられないので nil
    static func splitPending(_ shown: String, typed keys: String, table: RomajiTable) -> (kept: String, pending: Int)? {
        let letters = keys.reversed().prefix { $0.isASCII && $0.isLetter }
        let word = String(letters.reversed())
        let readable = word.indices.lazy.map { word[$0...] }.first { table.reading(of: $0) != nil }
        if let readable, table.readingBeforePendingN(readable) != nil, shown.hasSuffix("n") { return (String(shown.dropLast()), 1) }
        var consonants = String(letters.prefix { !"aiueo".contains($0) }.reversed())
        // 母音の直後の nn は読み終えた「ん」
        if consonants.hasPrefix("nn") { consonants.removeFirst(2) }
        guard !consonants.isEmpty else { return (shown, 0) }
        return shown.hasSuffix(consonants) ? (String(shown.dropLast(consonants.count)), consonants.count) : nil
    }

    /// 変換が届く前に見せる keys の読み。区切りと同じく、記号の打鍵は記号にし、句読点は直前が日本語なら日本語の記号にする。
    /// それ以外は前から、読める所は最も長く読んでかなにし、読めない打鍵は打ったまま残す（kar → かr）。
    /// 打っている途中の表示と同じく、末尾の単独の n（RomajiTable.readingBeforePendingN）は次の打鍵まで決めないので打ったまま残す。
    /// 数の区切り（isNumberSeparator、isNumberDash）も区切りと同じく打ったまま残す。preceding は keys の直前の文字
    static func provisionalText(of keys: some StringProtocol, afterJapanese startsAfterJapanese: Bool, preceding: Character?, table: RomajiTable) -> String {
        let input = Array(keys)
        var text = ""
        var afterJapanese = startsAfterJapanese
        var position = 0
        while position < input.count {
            if let symbol = symbol(at: position, in: input) {
                text += symbol.mark
                afterJapanese = true
                position += symbol.key.count
            } else if isNumberSeparator(at: position, in: input, before: preceding) {
                text.append(input[position])
                position += 1
            } else if afterJapanese, let mark = punctuation[input[position]] {
                text += mark
                position += 1
            } else if let longest = japaneseReadings(table: table, from: position, in: input, before: preceding).last(where: {
                $0.end < input.count || table.readingBeforePendingN(String(input[position...])) == nil
            }) {
                text += longest.kana
                afterJapanese = true
                position = longest.end
            } else {
                text.append(input[position])
                afterJapanese = false
                position += 1
            }
        }
        return text
    }
}
