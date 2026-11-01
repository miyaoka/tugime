import Foundation

/// 変換が届く前に、打った文字をすぐ見せるための読み
extension Segmenter {
    /// 打鍵列 keys の変換の表示 shown を、後ろに読みをつないでも崩れない部分と、末尾の打ちかけの打鍵の数に分ける。
    /// 打ちかけは、最後の母音より後ろの子音（表示に打ったまま出ている。読み終えた nn を除く）と、単独の n（表示では「ん」）。
    /// 打ちかけの打鍵は、後から打った打鍵とまとめて読み直す（g の後の i は「ぎ」、n の後の o は「の」）。
    /// 打ちかけの部分が表示の末尾にそのまま出ていなければ（ten の n が「点」に入っている）、分けられないので nil
    public static func splitPending(_ shown: String, typed keys: String) -> (kept: String, pending: Int)? {
        let letters = keys.reversed().prefix { $0.isASCII && $0.isLetter }
        if letters.first == "n", letters.dropFirst().first != "n" {
            return shown.hasSuffix("ん") ? (String(shown.dropLast()), 1) : nil
        }
        var consonants = String(letters.prefix { !"aiueo".contains($0) }.reversed())
        // 母音の直後の nn は読み終えた「ん」
        if consonants.hasPrefix("nn") { consonants.removeFirst(2) }
        guard !consonants.isEmpty else { return (shown, 0) }
        return shown.hasSuffix(consonants) ? (String(shown.dropLast(consonants.count)), consonants.count) : nil
    }

    /// 変換が届く前に、shown の後ろに見せる keys の読み。区切りと同じく、記号の打鍵は記号にし、句読点は直前がかなか日本語の記号なら日本語の記号にする。
    /// それ以外は前から、読める所は最も長く読んでかなにし、読めない打鍵は打ったまま残す（kar → かr）
    public static func provisionalText(of keys: some StringProtocol, after shown: String, table: RomajiTable) -> String {
        let input = Array(keys)
        var text = ""
        var afterJapanese = shown.last.map { !$0.isASCII } ?? true
        var position = 0
        while position < input.count {
            if let symbol = symbol(at: position, in: input) {
                text += symbol.mark
                afterJapanese = true
                position += symbol.key.count
            } else if afterJapanese, let mark = punctuation[input[position]] {
                text += mark
                position += 1
            } else if let longest = table.readings(from: position, in: input).last {
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
