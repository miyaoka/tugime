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
            let preceding = Preceding(split.kept.last ?? leading.text.last)
            let text = split.kept + provisionalText(
                of: rest, afterJapanese: afterJapanese(split.kept, leading: leading), preceding: preceding, table: table,
                opened: unclosedOpeners(in: leading.text + split.kept)
            )
            return LiveDisplay(text: text, differsFromInput: base.display.differsFromInput)
        }
        let text = provisionalText(
            of: keys, afterJapanese: afterJapanese("", leading: leading), preceding: Preceding(leading.text.last), table: table,
            opened: unclosedOpeners(in: leading.text)
        )
        return LiveDisplay(text: text, differsFromInput: false)
    }

    /// 打っている途中の Backspace の後の打鍵列と、残す表示。打鍵列 keys の表示 shown の末尾の 1 文字を、その下の打鍵ごと消し、残りは shown を切って作る
    /// （deletingLastShown）。shown の末尾の字に対応する打鍵が決まらない（利用者の辞書の語の表記、読みと合わない変換）と表示を残せないので、
    /// 打鍵の読みの最後の単位を消し（deletingLastTyped）、表示は nil（呼び出し側が変換し直す）
    public static func deletingLast(of keys: String, shown display: LiveDisplay, leading: Leading, table: RomajiTable) -> (keys: String, display: LiveDisplay?) {
        if let deleted = deletingLastShown(of: keys, shown: display.text, leading: leading, table: table) {
            return (deleted.keys, LiveDisplay(text: deleted.text, differsFromInput: display.differsFromInput))
        }
        return (deletingLastTyped(of: keys, shown: display.text, endsInEnglish: display.endsInEnglish, leading: leading, table: table), nil)
    }

    /// shown の末尾の 1 文字を、利用者が打ったかなの単位（kanaUnitLength）で、その下の打鍵ごと消した打鍵列と表示。
    /// 打ったままの文字（英字・数字・打ちかけの綴り）は 1 打鍵、句読点と記号はその打鍵、かなは最後の単位、漢字が 1 文字ならその読み、
    /// 2 文字以上の漢字の連なりは字ごとの読みが決まらないので、読みのかなに戻して最後の単位を消す。
    /// 打ったままの文字は、表示の末尾の ASCII の連なりが打鍵の末尾とそのまま一致するときだけ（利用者の辞書の語の表記は打ったままの文字ではない）。
    /// かなと漢字は、表示の中で最後の打ったままの文字・句読点・記号より後ろだけを、その後ろの打鍵の読みと照らす。対応づかなければ nil
    static func deletingLastShown(of keys: String, shown: String, leading: Leading, table: RomajiTable) -> (keys: String, text: String)? {
        guard let last = shown.last else { return nil }
        if last.isASCII {
            guard keys.hasSuffix(String(shown.reversed().prefix(while: \.isASCII).reversed())) else { return nil }
            return (String(keys.dropLast()), String(shown.dropLast()))
        }
        if let key = markKey(last, endingAt: keys.endIndex, in: keys) {
            let kept = keys.dropLast(key.count)
            let before = shown.dropLast()
            // 日本語の区間の句読点と記号の前の単独の n は ん と読まれ、消すと次のかなを待つ n に戻るので、綴りの表の ん の綴りにする
            // （日本。 の 。 を消した 日本 は nihonn）。英語の区間の n（kotlin「 の kotlin）は打ったまま
            let typing = Typing(
                keys: kept, afterJapanese: afterJapanese("", leading: leading), preceding: Preceding(leading.text.last), table: table,
                opened: unclosedOpeners(in: leading.text)
            )
            guard before.last?.isASCII == false, typing.reading.last == "n", let n = table.spelling(of: "ん") else { return (String(kept), String(before)) }
            return (kept.dropLast() + n.map(\.keys).joined(), String(before))
        }
        // 表示の末尾のかなと漢字の部分（tail）と、それを打った打鍵の位置。前の部分（head）の末尾の打ったままの字・句読点・記号の連なりを
        // そのとおりに打った打鍵の直後から始まる（data管理 の data）
        let tailLength = shown.reversed().prefix { !$0.isASCII && markKeys[$0] == nil }.count
        let head = shown.dropLast(tailLength)
        let tail = String(shown.suffix(tailLength))
        let typedRun = head.reversed().prefix { $0.isASCII || markKeys[$0] != nil }
        let starts = typedRun.isEmpty ? [keys.startIndex] : keys.indices.reversed().filter { start in
            var end = start
            for shown in typedRun {
                if shown.isASCII {
                    guard end > keys.startIndex, keys[keys.index(before: end)] == shown else { return false }
                    end = keys.index(before: end)
                } else {
                    guard let key = markKey(shown, endingAt: end, in: keys) else { return false }
                    end = keys.index(end, offsetBy: -key.count)
                }
            }
            return true
        }
        for start in starts {
            let preceding = Preceding(key: start > keys.startIndex ? keys[keys.index(before: start)] : leading.text.last, shown: head.last ?? leading.text.last)
            let typing = Typing(
                keys: keys[start...], afterJapanese: afterJapanese(String(head), leading: leading), preceding: preceding, table: table,
                opened: unclosedOpeners(in: leading.text + head)
            )
            guard let kept = typing.deletingLast(of: tail) else { continue }
            return (String(keys[..<start]) + kept.keys, String(head) + kept.text)
        }
        return nil
    }

    /// 表示を残せないときの Backspace の後の打鍵列。打鍵の読みの最後の単位を消す。英語の区間の字と、読みが打ちかけで終わる打鍵は 1 打鍵。
    /// 英語の区間かは、区切りの結果から作った表示なら endsInEnglish で決まる（Kubernetes と en で登録した kube は 1 打鍵、
    /// Fiji と ja で登録した kanji は打ったかなの単位）。それ以外の表示では、末尾の英字が打ったままか（大文字と小文字を除いて打鍵の末尾と一致するか）で決める
    static func deletingLastTyped(of keys: String, shown: String, endsInEnglish: Bool?, leading: Leading, table: RomajiTable) -> String {
        let typed = String(shown.reversed().prefix(while: \.isASCII).reversed()).lowercased()
        if endsInEnglish ?? (!typed.isEmpty && keys.lowercased().hasSuffix(typed)) { return String(keys.dropLast()) }
        let typing = Typing(
            keys: keys[...], afterJapanese: afterJapanese("", leading: leading), preceding: Preceding(leading.text.last), table: table,
            opened: unclosedOpeners(in: leading.text)
        )
        guard typing.reading.last?.isASCII == false, let kept = typing.keys(droppingReading: kanaUnitLength(typing.reading)) else {
            return String(keys.dropLast())
        }
        return kept
    }

    /// 打鍵列 keys と、それを綴りの表で読んだかな
    private struct Typing {
        let keys: Substring
        let afterJapanese: Bool
        let preceding: Preceding
        let table: RomajiTable
        /// keys より前の閉じていない開き丸括弧
        let opened: [Character]
        let reading: String

        init(keys: Substring, afterJapanese: Bool, preceding: Preceding, table: RomajiTable, opened: [Character]) {
            self.keys = keys
            self.afterJapanese = afterJapanese
            self.preceding = preceding
            self.table = table
            self.opened = opened
            reading = Segmenter.provisionalText(of: keys, afterJapanese: afterJapanese, preceding: preceding, table: table, opened: opened)
        }

        private func read(_ typed: Substring) -> String {
            Segmenter.provisionalText(of: typed, afterJapanese: afterJapanese, preceding: preceding, table: table, opened: opened)
        }

        /// 読みを末尾から count 文字落とした読みを打つ打鍵列。打鍵列の頭のうち、読みがその読みの頭になる最も長いものに、残りのかなを綴りの表で打つ綴りを足す。
        /// 残りが出るのは、読みが っ か ん で終わるとき。子音を重ねた っ と単独の n の ん は、次のかなが続くまで っ と ん に読まれないので
        /// （特許 から きょ を消した とっ は tok では とk、感じ から じ を消した かん は kan では かn）、綴りの表の綴り（xtu、nn）にする
        func keys(droppingReading count: Int) -> String? {
            let target = reading.dropLast(count)
            for kept in (0...keys.count).lazy.map({ keys.dropLast($0) }) {
                let read = read(kept)
                if read == target { return String(kept) }
                guard target.hasPrefix(read), read.last?.isASCII != true else { continue }
                guard let rest = table.spelling(of: String(target.dropFirst(read.count))) else { return nil }
                return kept + rest.map(\.keys).joined()
            }
            return nil
        }

        /// かなと漢字の表示 text の末尾の 1 文字を消した打鍵列と表示。末尾のかなの単位が読みの末尾と合わないか、漢字の連なりの位置が読みの上で決まらなければ nil。
        /// 末尾のかなより前の、読みと合わない変換は照らさない（残せるかは keepDisplay が決める）
        func deletingLast(of text: String) -> (keys: String, text: String)? {
            guard let last = text.last else { return nil }
            let unit = Segmenter.kanaUnitLength(reading)
            if ReadingAlignment.anchor(last) != nil {
                let shownUnit = text.suffix(unit)
                guard shownUnit.count == unit, zip(shownUnit, reading.suffix(unit)).allSatisfy({ ReadingAlignment.anchor($0) == $1 }),
                      let kept = keys(droppingReading: unit)
                else { return nil }
                return (kept, String(text.dropLast(unit)))
            }
            let run = text.reversed().prefix { ReadingAlignment.anchor($0) == nil }.count
            guard let start = ReadingAlignment(text: text, reading: reading)?.fixed[text.count - run] else { return nil }
            let head = String(text.dropLast(run))
            if run == 1 {
                guard let kept = keys(droppingReading: reading.count - start) else { return nil }
                return (kept, head)
            }
            guard reading.count - unit >= start, let kept = keys(droppingReading: unit) else { return nil }
            return (kept, head + reading.dropFirst(start).dropLast(unit))
        }
    }

    /// 読み reading の末尾の、利用者が打ったかな 1 単位の長さ。単位はかな 1 文字で、小書きのかな（ゃ ゅ ょ ぁ…）は前のかなと合わせて 1 単位に打つ（kyo の きょ）。
    /// っ は子音を重ねて打つ 1 単位
    static func kanaUnitLength(_ reading: String) -> Int {
        min(reading.count, reading.reversed().prefix { smallKana.contains($0) }.count + 1)
    }

    /// 前のかなと合わせて 1 単位に打つ小書きのかな
    static let smallKana: Set<Character> = ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ"]

    /// keys の end までの末尾にある、表示 mark を出す句読点か記号の打鍵。最も長いもの
    private static func markKey(_ mark: Character, endingAt end: String.Index, in keys: String) -> String? {
        markKeys[mark]?.filter { keys[..<end].hasSuffix($0) }.max { $0.count < $1.count }
    }

    /// Backspace で残した表示 text を、打鍵列 input の表示として覚える。以後この未確定の文字列のあいだ、input の打っている途中の表示と文節は、
    /// 日本語区間を変換し直さずに text から作る（文節の選択に入っても、見えていた表記のまま）。
    /// text を input の区間に割り当てられなければ、何も覚えずに nil を返す
    public func keepDisplay(_ text: String, for input: String, leading: Leading) -> LiveDisplay? {
        let previous = keptDisplays
        let (shown, reached) = Unexpected.watching { () -> LiveDisplay? in
            let segments = segment(input, leading: leading)
            var kept: [KeptDisplayKey: JapaneseDisplay] = [:]
            // 打っている途中の表示は末尾の単独の n を外した区切り（keepingPendingN）、文節は外さない区切りで作るので、両方に割り当てる
            for spans in [segments, keepingPendingN(segments).segments] {
                guard let pieces = keptPieces(text, over: spans, leading: leading) else { return nil }
                kept.merge(pieces) { $1 }
            }
            keptDisplays.merge(kept) { $1 }
            return liveDisplay(input, leading: leading)
        }
        guard !reached, let shown, shown.text == text else {
            keptDisplays = previous
            return nil
        }
        return shown
    }

    /// text を区間 segments の表示に前から割り当てる。日本語以外の区間には区間の表記がそのまま現れる。日本語区間は次の区間の表記の手前までを取り、
    /// その読みと対応づかなければ割り当てられない（nil）
    private func keptPieces(_ text: String, over segments: [Segment], leading: Leading) -> [KeptDisplayKey: JapaneseDisplay]? {
        var rest = Substring(text)
        var left = leading.text
        var kept: [KeptDisplayKey: JapaneseDisplay] = [:]
        // 句読点は、表示と同じく前に見えている文字列で決め直した形で照らす（shownSegments）
        var punctuation = ShownPunctuation()
        for (index, typed) in segments.enumerated() {
            let segment = punctuation.decide(typed, shown: left)
            let piece: String
            if segment.kind == .japanese {
                // 次の句読点の区間は、決め直す前と後（打ったまま）のどちらの形でも表示に現れうるので、先に現れる方の手前まで
                let end = segments.dropFirst(index + 1).first.flatMap { next in
                    (next.kind == .punctuation ? [next.output, next.source] : [next.output]).compactMap { rest.range(of: $0)?.lowerBound }.min()
                } ?? rest.endIndex
                piece = String(rest[..<end])
                guard !piece.isEmpty, ReadingAlignment(text: piece, reading: segment.reading) != nil else { return nil }
                let scored = japaneseConverter.convert(kana: segment.reading, context: segment.context).clauses
                let clauses = DirectConverter.clauses(of: piece, kana: segment.reading, scored: scored)
                kept[KeptDisplayKey(kana: segment.reading, context: segment.context, left: left)] =
                    JapaneseDisplay(text: piece, clauses: clauses, userWords: scored.flatMap(\.userWords))
            } else {
                guard rest.hasPrefix(segment.output) else { return nil }
                piece = segment.output
            }
            left += piece
            rest = rest.dropFirst(piece.count)
        }
        return rest.isEmpty ? kept : nil
    }

    /// 表示 shown の後ろの句読点を日本語の記号にするか。入力欄の直前に表示をつないだものを前の文字列とみなし、区切りと確定してから打ったときと同じ
    /// keepsPunctuationTyped(afterText:) で決める
    static func afterJapanese(_ shown: String, leading: Leading) -> Bool {
        !keepsPunctuationTyped(afterText: leading.text + shown)
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
    /// 数の区切り（isNumberSeparator）と、日本語の文字の後ろにない -（lengthensOnlyJapanese）も区切りと同じく打ったまま残す。preceding は keys の直前。
    /// opened は keys より前の閉じていない開き丸括弧で、閉じ丸括弧は区切りと同じく組の開き丸括弧の形にする（punctuationMark）
    static func provisionalText(
        of keys: some StringProtocol, afterJapanese startsAfterJapanese: Bool, preceding: Preceding, table: RomajiTable, opened: [Character]
    ) -> String {
        let input = Array(keys)
        var text = ""
        var afterJapanese = startsAfterJapanese
        var opened = opened
        var position = 0
        while position < input.count {
            if let symbol = symbol(at: position, in: input) {
                text += symbol.mark
                afterJapanese = true
                position += symbol.key.count
            } else if isNumberSeparator(at: position, in: input, before: preceding.key) || input[position] == " " {
                // 空白は句読点の形を決める直前の側を変えない
                text.append(input[position])
                position += 1
            } else if punctuation[input[position]] != nil,
                      let mark = punctuationMark(input[position], opened: &opened, previousIsEnglish: !afterJapanese) {
                text += mark
                // 記号の後ろは区切りと同じく、日本語の記号の後なら日本語の側、組に合わせて半角にした閉じ丸括弧の後なら英語の側
                afterJapanese = continuation(after: String(input[position]), mark: mark) != .afterEnglish
                position += 1
            } else if let longest = japaneseReadings(table: table, from: position, in: input, before: preceding).last(where: {
                $0.end < input.count || table.readingBeforePendingN(String(input[position...])) == nil
            }) {
                text += longest.kana
                // 数字は日本語でも英語でもないので、数字だけの読みは直前の側を変えない（html5. の . は打ったまま）
                if !isNumber(longest.kana) { afterJapanese = true }
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
