import Foundation

/// 確定前の 1 文節。日本語区間は変換エンジンの文節に分け、英語区間と句読点はそれぞれ 1 文節にする。候補の窓で選び直せる
public struct Clause: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        case punctuation
        /// 未確定の文字列全体を 1 つの文字種にした文節（F6〜F10）。読みは全体の読み（`wholeReading`）
        case whole

        init(_ kind: Segment.Kind) {
            switch kind {
            case .japanese: self = .japanese
            case .english: self = .english
            case .punctuation: self = .punctuation
            }
        }
    }

    public var kind: Kind
    /// 日本語はかな、全体の変換は全体の読み、それ以外は打ったまま
    public var reading: String
    /// 先頭が区切りを選んだときの結果。重複は無い
    public var candidates: [String]
    public var selected: Int
    /// この文節を含む区間。同じ区間の文節は同じ値を持つ
    public var span: ClauseSpan

    public init(kind: Kind, reading: String, candidates: [String], selected: Int, span: ClauseSpan) {
        self.kind = kind
        self.reading = reading
        self.candidates = candidates
        self.selected = selected
        self.span = span
    }

    public var output: String { candidates[selected] }
}

/// 日英判定で決めた 1 区間
public struct ClauseSpan: Sendable, Equatable {
    /// 未確定の文字列の中で何番目の区間か
    public var index: Int
    /// 打鍵列のうちこの区間に当たる部分
    public var source: String
    /// 日本語ならかな、それ以外は打ったまま
    public var reading: String
    /// 区間の先頭の文節を変換するときの文脈
    public var context: JapaneseContext
    /// 区切りの選択ではなく、文節の伸縮で利用者が打鍵の範囲を決めた区間か
    public var resized: Bool

    public init(index: Int, source: String, reading: String, context: JapaneseContext, resized: Bool = false) {
        self.index = index
        self.source = source
        self.reading = reading
        self.context = context
        self.resized = resized
    }
}

extension Segmenter {
    /// 区切りを選び、日本語区間を文節に分けて、文節ごとに候補の一覧を付ける。
    /// 日本語区間は、前の区間の表示を左の文脈にして表示の変換で文節に分ける
    public func clauses(_ input: String, leading: Leading = .start) -> [Clause] {
        clauses(of: segment(input, leading: leading), left: "", firstIndex: 0)
    }

    /// 区間を、left に続けて表示の変換にし、文節に分ける。区間の番号は firstIndex から振る
    private func clauses(of segments: [Segment], left: String, firstIndex: Int) -> [Clause] {
        zip(segments, displays(of: segments.map(ShownSpan.init), left: left)).enumerated().flatMap { offset, pair in
            let (segment, display) = pair
            let span = ClauseSpan(index: firstIndex + offset, source: segment.source, reading: segment.reading, context: segment.context)
            guard let display else {
                return [Clause(kind: Clause.Kind(segment.kind), reading: segment.reading, candidates: candidates(for: segment), selected: 0, span: span)]
            }
            return japaneseClauses(display.clauses, context: span.context, in: span)
        }
    }

    /// 文節を伸ばす（delta が正）・縮める（負）。区切りの選択が決めた日本語の区間の中では、区間の読みのかなの上で 1 かなずつ伸縮し、
    /// 1 かなより短くしない（`resizeInsideSpan`）。文節の始まりが 1 つの綴りの途中にあって打鍵を切り出せないときも同じにする。
    /// それ以外（区間の終わりを越えて伸ばすとき、英語の文節、伸縮で作った区間の文節）は、打鍵列の上で文節の終わりを 1 単位ずつ動かし
    /// （`unitEnd`、`unitStart`）、文節の打鍵を 1 区間として日英を判定して、後ろの打鍵は日英判定と変換をやり直す（`rebuild`）。
    /// 句読点と記号の文節は伸縮しない。全体を 1 つの文字種にした文節は、区切りから文節を作り直して最初の文節を伸縮する。
    /// 伸縮できなければ元のまま返す
    public func resize(_ clauses: [Clause], at index: Int, by delta: Int, leading: Leading = .start) -> [Clause] {
        let clause = clauses[index]
        if clause.kind == .whole {
            let segmented = self.clauses(clause.span.source, leading: leading)
            let resized = resize(segmented, at: 0, by: delta, leading: leading)
            return resized == segmented ? clauses : resized
        }
        guard clause.kind != .punctuation else { return clauses }
        let spans = keySpans(of: clauses)
        let keys = Array(spans.map(\.span.source).joined())
        guard let own = spans.first(where: { $0.span == clause.span }) else { return clauses }
        guard let range = keyRange(of: clauses, at: index, from: own.start) else {
            return resizeInsideSpan(clauses, at: index, by: delta) ?? clauses
        }
        if clause.kind == .japanese, !clause.span.resized {
            let length = clause.reading.count + delta
            guard length >= 1 else { return clauses }
            if kanaStart(of: clauses, at: index) + length <= clause.span.reading.count {
                return resizeInsideSpan(clauses, at: index, by: delta) ?? clauses
            }
        }
        var end = range.upperBound
        for _ in 0..<abs(delta) {
            guard let next = delta > 0 ? unitEnd(from: end, in: spans) : unitStart(before: end, in: spans), next > range.lowerBound else {
                return clauses
            }
            end = next
        }
        return rebuild(clauses, at: index, keys: keys, spanStart: own.start, range: range, end: end, leading: leading)
    }

    /// 文節の打鍵 range.lowerBound..<end と、その直前に並ぶ文節を合わせたものが、打鍵列の全体を区切りの選択にかけたときの
    /// 1 区間にちょうど当たるか。当たれば、その区間と、区間に含まれる直前の文節の数を返す。
    /// 直前の文節は日本語の区間の文節だけで、読みをつなぐと区間の読みになるものを数える。
    /// 数えた文節の区間は丸ごと含まれ、その始まりが区切りの選択の区間の始まりと打鍵の位置で一致するときだけ当たったとする
    private func segmentedSpan(
        _ fixed: Segment, before: [Clause], start: Int, end: Int, keys: [Character], leading: Leading
    ) -> (segment: Segment, count: Int)? {
        let spans = keySpans(of: before)
        var position = 0
        for segment in segment(String(keys), leading: leading) {
            let next = position + segment.source.count
            defer { position = next }
            guard position <= start, next == end, segment.kind == fixed.kind else { continue }
            var reading = fixed.reading
            var count = 0
            while reading.count < segment.reading.count, count < before.count, before[before.count - 1 - count].kind == .japanese {
                reading = before[before.count - 1 - count].reading + reading
                count += 1
            }
            guard reading == segment.reading else { return nil }
            let first = before.count - count
            guard first < before.count else { return position == start ? (segment, 0) : nil }
            let wholeSpan = first == 0 || before[first - 1].span != before[first].span
            guard wholeSpan, spans.first(where: { $0.span == before[first].span })?.start == position else { return nil }
            return (segment, count)
        }
        return nil
    }

    /// 日本語の文節を、区間の読みのかなの上で 1 かなずつ伸縮する。区間の外へは伸ばさず、1 かなより短くしない。
    /// 伸縮した文節の後ろにある同じ区間の残りは、日本語のまま文節に分け直して変換する。後ろの区間は、伸縮した区間の表示を左の文脈にして
    /// 表示の変換をし直す。伸縮できなければ nil
    private func resizeInsideSpan(_ clauses: [Clause], at index: Int, by delta: Int) -> [Clause]? {
        let clause = clauses[index]
        guard clause.kind == .japanese else { return nil }
        let span = clause.span
        let spanIndices = clauses.indices.filter { clauses[$0].span == span }
        let start = kanaStart(of: clauses, at: index)
        let length = clause.reading.count + delta
        guard length >= 1, start + length <= span.reading.count else { return nil }

        let reading = String(span.reading.dropFirst(start).prefix(length))
        let context = start == 0 ? span.context : .afterWord
        let left = clauses[..<index].map(\.output).joined()
        let resized = Clause(
            kind: .japanese,
            reading: reading,
            candidates: japaneseCandidates(reading: reading, best: japaneseConverter.display(kana: reading, context: context, left: left)?.text, context: context, span: span),
            selected: 0,
            span: span
        )
        let restKana = String(span.reading.dropFirst(start + length))
        let rest = restKana.isEmpty ? [] : japaneseClauses(
            japaneseConverter.display(kana: restKana, context: .afterWord, left: left + resized.output)?.clauses ?? [JapaneseClause(reading: restKana, text: restKana)],
            context: .afterWord,
            in: span
        )
        let later = redisplay(Array(clauses[(spanIndices.last! + 1)...]), left: left + ([resized] + rest).map(\.output).joined())
        return Array(clauses[..<index]) + [resized] + rest + later
    }

    /// index の文節を打鍵列の range.lowerBound..<end にして、その打鍵を 1 区間として日英を判定する。
    /// 後ろの打鍵は、その文節の表示を左の文脈にして日英判定と変換をやり直す。range は文節の今の打鍵、spanStart はその区間の始まり。
    /// 同じ区間の前の文節は、文節の始まりまでを 1 つの区間として持ち直す。そのうえで、直前の文節と合わせた打鍵が区切りの選択の
    /// 1 区間と一致すれば（伸ばして元に戻したとき）、それらの文節をその区間に戻す。一致しなければ、文節は伸縮で作った区間にする
    private func rebuild(
        _ clauses: [Clause], at index: Int, keys: [Character], spanStart: Int, range: Range<Int>, end: Int, leading: Leading
    ) -> [Clause] {
        let clause = clauses[index]
        var before = Array(clauses[..<index])
        let head = ClauseSpan(
            index: clause.span.index,
            source: String(keys[spanStart..<range.lowerBound]),
            reading: String(clause.span.reading.prefix(kanaStart(of: clauses, at: index))),
            context: clause.span.context,
            resized: clause.span.resized
        )
        for i in before.indices where before[i].span == clause.span {
            before[i].span = head
        }
        let left = before.map(\.output).joined()
        let fixed = singleSpan(String(keys[range.lowerBound..<end]), context: context(after: before.last, keys: keys[..<range.lowerBound], leading: leading))
        let span: ClauseSpan
        if let (segmented, count) = segmentedSpan(fixed, before: before, start: range.lowerBound, end: end, keys: keys, leading: leading) {
            let first = before.count - count
            span = ClauseSpan(
                index: first < before.count ? before[first].span.index : (before.last?.span.index ?? -1) + 1,
                source: segmented.source,
                reading: segmented.reading,
                context: segmented.context
            )
            for i in first..<before.count {
                before[i].span = span
            }
        } else {
            span = ClauseSpan(index: (before.last?.span.index ?? -1) + 1, source: fixed.source, reading: fixed.reading, context: fixed.context, resized: true)
        }
        // 区間の 2 つ目以降の文節は、前の文節に続く形で変換する
        let clauseContext = before.last?.span == span ? JapaneseContext.afterWord : span.context
        let resized = fixed.kind == .japanese
            ? Clause(
                kind: .japanese,
                reading: fixed.reading,
                candidates: japaneseCandidates(
                    reading: fixed.reading,
                    best: japaneseConverter.display(kana: fixed.reading, context: clauseContext, left: left)?.text,
                    context: clauseContext,
                    span: span
                ),
                selected: 0,
                span: span
            )
            : Clause(kind: Clause.Kind(fixed.kind), reading: fixed.reading, candidates: candidates(for: fixed), selected: 0, span: span)
        let rest = self.clauses(
            of: segment(
                String(keys[end...]),
                leading: fixed.kind == .japanese ? .afterJapanese : .afterEnglish,
                context: context(after: resized, keys: keys[..<end], leading: leading)
            ),
            left: left + resized.output,
            firstIndex: span.index + 1
        )
        return before + [resized] + rest
    }

    /// 未確定の打鍵列の中での区間の位置
    private struct KeySpan {
        var span: ClauseSpan
        var kind: Clause.Kind
        var start: Int
        var end: Int { start + span.source.count }
    }

    private func keySpans(of clauses: [Clause]) -> [KeySpan] {
        var spans: [KeySpan] = []
        for clause in clauses where clause.span != spans.last?.span {
            spans.append(KeySpan(span: clause.span, kind: clause.kind, start: spans.last?.end ?? 0))
        }
        return spans
    }

    /// index の文節に当たる、未確定の打鍵列の範囲。spanStart はその文節の区間の始まり。文節の境目が 1 つの綴りの途中に当たれば nil
    private func keyRange(of clauses: [Clause], at index: Int, from spanStart: Int) -> Range<Int>? {
        let clause = clauses[index]
        guard let typed = typedSource(of: clauses, at: index),
              let before = clause.kind == .japanese ? splitSource(of: clause.span, atKana: kanaStart(of: clauses, at: index))?.head : ""
        else { return nil }
        let start = spanStart + before.count
        return start..<(start + typed.count)
    }

    /// 打鍵列の position から始まる、文節が取り込む 1 単位の終わり。日本語の区間では読み切れる最短の綴り（っ と単独の ん は
    /// 次のかなと合わせる）、英語の区間では 1 打鍵（打ったままの句読点を含む）。
    /// 句読点と記号の区間と、打鍵列の終わりでは nil
    private func unitEnd(from position: Int, in spans: [KeySpan]) -> Int? {
        guard let next = spans.first(where: { $0.start <= position && position < $0.end }) else { return nil }
        switch next.kind {
        case .punctuation, .whole:
            return nil
        case .english:
            return position + 1
        case .japanese:
            return table.readings(from: position - next.start, in: Array(next.span.source)).first.map { next.start + $0.end }
        }
    }

    /// 打鍵列の position で終わる、文節が手放す 1 単位の始まり。日本語の区間では区間の始まりから読み切れる綴りの境目のうち
    /// position より前で最も後ろのもの、英語の区間では 1 打鍵前。句読点と記号の区間と、打鍵列の始まりでは nil
    private func unitStart(before position: Int, in spans: [KeySpan]) -> Int? {
        guard let span = spans.first(where: { $0.start < position && position <= $0.end }) else { return nil }
        switch span.kind {
        case .punctuation, .whole:
            return nil
        case .english:
            return position - 1
        case .japanese:
            return table.readings(from: 0, in: Array(span.span.source)).map { span.start + $0.end }.filter { $0 < position }.max() ?? span.start
        }
    }

    /// 文節を変換する文脈。英語の後は前の語に続く形（数字の後は助数詞）、日本語の後は前の文節に続く形、
    /// 句読点と記号の後は区切りの選択と同じ形
    private func context(after previous: Clause?, keys: ArraySlice<Character>, leading: Leading) -> JapaneseContext {
        guard let previous else { return leading.japaneseContext }
        switch previous.kind {
        case .english:
            return Self.context(after: keys)
        case .japanese:
            return .afterWord
        case .punctuation:
            return Self.leading(after: previous.span.source).japaneseContext
        case .whole:
            preconditionFailure("全体の変換の文節は 1 つだけで、後ろに文節を持たない")
        }
    }

    /// 区間ごとの文節を、left に続けて前から順に表示の変換にし直す。日本語区間は文節に分け直し、それ以外の区間は選んだ文字列のまま残す
    private func redisplay(_ clauses: [Clause], left: String) -> [Clause] {
        var groups: [[Clause]] = []
        for clause in clauses {
            if let last = groups.last?.last, last.span == clause.span {
                groups[groups.count - 1].append(clause)
            } else {
                groups.append([clause])
            }
        }
        let spans = groups.map { group in
            group[0].kind == .japanese
                ? ShownSpan.japanese(kana: group[0].span.reading, context: group[0].span.context)
                : ShownSpan.fixed(group.map(\.output).joined())
        }
        return zip(groups, displays(of: spans, left: left)).flatMap { group, display in
            display.map { japaneseClauses($0.clauses, context: group[0].span.context, in: group[0].span) } ?? group
        }
    }

    /// index の文節までを確定するときの、確定する文字列、残りの文節、残りの打鍵列。
    /// 日本語区間の途中で切るときは、残りをその位置から始まる区間として持ち直す。切る位置に当たる打鍵が決まらなければ nil
    public func commit(_ clauses: [Clause], through index: Int) -> (text: String, rest: [Clause], keys: String)? {
        let text = clauses[...index].map(\.output).joined()
        var rest = Array(clauses[(index + 1)...])
        if let next = rest.first, next.span == clauses[index].span {
            let span = next.span
            let done = kanaStart(of: clauses, at: index + 1)
            guard let (_, tail) = splitSource(of: span, atKana: done) else { return nil }
            let remaining = ClauseSpan(index: span.index, source: tail, reading: String(span.reading.dropFirst(done)), context: .afterWord, resized: span.resized)
            for i in rest.indices where rest[i].span == span {
                rest[i].span = remaining
            }
        }
        var keys = ""
        var lastSpan: ClauseSpan?
        for clause in rest where clause.span != lastSpan {
            keys += clause.span.source
            lastSpan = clause.span
        }
        return (text, rest, keys)
    }

    /// index の文節が、その区間の読みの何かな目から始まるか
    func kanaStart(of clauses: [Clause], at index: Int) -> Int {
        let span = clauses[index].span
        return clauses[..<index].filter { $0.span == span }.map(\.reading.count).reduce(0, +)
    }

    /// 区間の打鍵を、読みの kana かな目に当たる位置で切る。1 つの綴りの途中に当たれば nil
    func splitSource(of span: ClauseSpan, atKana kana: Int) -> (head: String, tail: String)? {
        if kana == 0 { return ("", span.source) }
        if kana == span.reading.count { return (span.source, "") }
        return table.split(span.source, kana: span.reading, atKana: kana)
    }

    /// index の文節に当たる打鍵。英語と句読点の文節は区間と同じ。日本語の文節の境目が 1 つの綴りの途中に当たれば nil
    func typedSource(of clauses: [Clause], at index: Int) -> String? {
        let clause = clauses[index]
        guard clause.kind == .japanese else { return clause.span.source }
        let start = kanaStart(of: clauses, at: index)
        guard let before = splitSource(of: clause.span, atKana: start)?.head,
              let through = splitSource(of: clause.span, atKana: start + clause.reading.count)?.head
        else { return nil }
        return String(through.dropFirst(before.count))
    }

    /// 表示の変換の文節を、候補の一覧を付けた文節にする。context は先頭の文節を変換した文脈
    private func japaneseClauses(_ parts: [JapaneseClause], context: JapaneseContext, in span: ClauseSpan) -> [Clause] {
        parts.enumerated().map { index, part in
            Clause(
                kind: .japanese,
                reading: part.reading,
                candidates: japaneseCandidates(reading: part.reading, best: part.text, context: index == 0 ? context : .afterWord, span: span),
                selected: 0,
                span: span
            )
        }
    }

    private func japaneseCandidates(reading: String, best: String?, context: JapaneseContext, span: ClauseSpan) -> [String] {
        var list = (best.map { [$0] } ?? []) + japaneseConverter.alternatives(kana: reading, context: context)
        list += [reading, Self.katakana(reading)]
        // 区間全体の文節なら、打ったままの綴りも選べるようにする
        if reading == span.reading { list.append(span.source) }
        return Self.unique(list)
    }

    private func candidates(for segment: Segment) -> [String] {
        var list: [String] = [segment.output]
        switch segment.kind {
        case .punctuation:
            list.append(segment.source)
        case .japanese:
            preconditionFailure("日本語区間は japaneseClauses で文節に分ける")
        case .english:
            // 英語と判定した区間も、`englishReading` で読めればかなを選べるようにする
            if let kana = englishReading(of: segment.source) {
                list += [kana, Self.katakana(kana)]
                // 変換エンジンには前後の空白を除いた 1 語の読みを渡し、候補に空白を付け直す
                let head = String(kana.prefix { $0 == " " })
                let tail = String(kana.reversed().prefix { $0 == " " })
                let word = kana.trimmingCharacters(in: .init(charactersIn: " "))
                if !word.contains(" "), let resolved = japaneseConverter.convert(kana: word, context: segment.context)?.context {
                    list += japaneseConverter.alternatives(kana: word, context: resolved).map { head + $0 + tail }
                }
            }
        }
        return Self.unique(list)
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen: Set<String> = []
        return list.filter { seen.insert($0).inserted }
    }

    private static func katakana(_ hiragana: String) -> String {
        hiragana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? hiragana
    }
}
