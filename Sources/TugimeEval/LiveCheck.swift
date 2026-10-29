import TugimeCore

/// 打っている途中の 1 打鍵の表示が、打ち終えたときの正解に向かっているかの判定。
/// 表示の末尾の、綴りの表でまだかなに読み切れない打鍵（ありm の m、いっt の t）は打ちかけなので除いて判定する
public enum LiveCheck: String, Sendable, CaseIterable {
    /// 打ちかけを除いた表示が、正解のどれかの先頭に一致するか、正解の先頭に続けてその先の読みをかなのまま見せている
    case followsAnswer = "正解の先頭"
    /// 正解に英字が無いのに、打ちかけを除いた表示に英字が残る（ありm → arim）
    case leftLetters = "英字が残る"
    /// どちらでもない。打ちかけの読みが別の語になった（しょうがん → 賞玩）など
    case offAnswer = "正解から外れる"

    /// typed はその打鍵までの打鍵列、reading は打ち終えたときの読み
    public static func judge(display: String, typed: String, answers: [String], reading: String, table: RomajiTable) -> LiveCheck {
        let chars = Array(typed)
        // 綴りの表は句読点と記号を読まないので、最後の句読点か記号の後ろから読む
        let runStart = Segmenter.lastMarkEnd(in: chars)
        let readEnd = table.readings(from: runStart, in: chars).last?.end ?? runStart
        // 読み切れない打鍵のうち、表示の末尾に打ったまま出ている分（いっt の t）
        let unread = chars[readEnd...]
        let shownUnread = (0...unread.count).reversed().first { display.hasSuffix(String(unread.suffix($0))) } ?? 0
        let shown = String(display.dropLast(shownUnread))
        if !answers.contains(where: hasLetter), hasLetter(shown) { return .leftLetters }
        if answers.contains(where: { follows(shown, answer: $0, reading: reading) }) { return .followsAnswer }
        return .offAnswer
    }

    /// shown が answer の先頭か、answer の読みの位置が確定した箇所までの先頭に、その先の読みのかなを続けたものか
    static func follows(_ shown: String, answer: String, reading: String) -> Bool {
        if answer.hasPrefix(shown) { return true }
        // 打鍵から作る句読点と記号は正解にも読みにもそのまま出る。表示の最後の記号までが正解の先頭に一致すれば、その後ろを正解と読みの残りで判定する
        if let last = shown.lastIndex(where: isMark) {
            let head = shown[...last]
            guard answer.hasPrefix(head) else { return false }
            let marks = head.filter(isMark).count
            guard let cut = reading.indices.filter({ isMark(reading[$0]) }).dropFirst(marks - 1).first else { return false }
            return follows(String(shown[shown.index(after: last)...]), answer: String(answer.dropFirst(head.count)), reading: String(reading[reading.index(after: cut)...]))
        }
        guard let alignment = ReadingAlignment(text: answer, reading: reading) else { return false }
        let text = Array(answer)
        let shownChars = Array(shown)
        let readingChars = Array(reading)
        for cut in 0...min(text.count, shownChars.count) {
            if cut > 0, shownChars[cut - 1] != text[cut - 1] { break }
            guard let position = alignment.readingPosition(atText: cut) else { continue }
            let tail = shownChars[cut...]
            guard tail.count <= readingChars.count - position else { continue }
            if zip(tail, readingChars[position...]).allSatisfy({ ReadingAlignment.anchor($0) == $1 }) { return true }
        }
        return false
    }

    private static func isMark(_ c: Character) -> Bool {
        Segmenter.marks.contains(c)
    }

    private static func hasLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
    }
}
