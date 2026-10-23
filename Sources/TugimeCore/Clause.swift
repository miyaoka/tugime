import Foundation

/// 確定前の 1 文節。日本語区間は変換エンジンの文節に分け、英語区間と句読点はそれぞれ 1 文節にする。候補の窓で選び直せる
public struct Clause: Sendable, Equatable {
    public var kind: Segment.Kind
    /// 日本語はかな、それ以外は打ったまま
    public var reading: String
    /// 先頭が区切りを選んだときの結果。重複は無い
    public var candidates: [String]
    public var selected: Int
    /// この文節を含む区間。同じ区間の文節は同じ値を持ち、文節の伸縮はこの中で行う
    public var span: ClauseSpan

    public init(kind: Segment.Kind, reading: String, candidates: [String], selected: Int, span: ClauseSpan) {
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

    public init(index: Int, source: String, reading: String, context: JapaneseContext) {
        self.index = index
        self.source = source
        self.reading = reading
        self.context = context
    }
}

extension Segmenter {
    /// 区切りを選び、日本語区間を文節に分けて、文節ごとに候補の一覧を付ける。
    /// 日本語区間は、前の区間の表示を左の文脈にして表示の変換で文節に分ける
    public func clauses(_ input: String, leading: Leading = .start) -> [Clause] {
        let segments = segment(input, leading: leading)
        return zip(segments, displays(of: segments.map(ShownSpan.init))).enumerated().flatMap { index, pair in
            let (segment, display) = pair
            let span = ClauseSpan(index: index, source: segment.source, reading: segment.reading, context: segment.context)
            guard let display else {
                return [Clause(kind: segment.kind, reading: segment.reading, candidates: candidates(for: segment), selected: 0, span: span)]
            }
            return japaneseClauses(display.clauses, context: span.context, in: span)
        }
    }

    /// 日本語の文節を 1 かなずつ伸ばす（delta が正）・縮める（負）。区間の外へは伸ばさず、1 かなより短くしない。
    /// 伸縮した文節の後ろにある同じ区間の残りは、文節に分け直して変換する。後ろの区間は、伸縮した区間の表示を左の文脈にして
    /// 表示の変換をし直す。伸縮できなければ元のまま返す
    public func resize(_ clauses: [Clause], at index: Int, by delta: Int) -> [Clause] {
        let clause = clauses[index]
        guard clause.kind == .japanese else { return clauses }
        let span = clause.span
        let spanIndices = clauses.indices.filter { clauses[$0].span == span }
        let start = kanaStart(of: clauses, at: index)
        let length = clause.reading.count + delta
        guard length >= 1, start + length <= span.reading.count else { return clauses }

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
            let remaining = ClauseSpan(index: span.index, source: tail, reading: String(span.reading.dropFirst(done)), context: .afterWord)
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
            // 英語と判定した区間も、綴りの表で読めればかなを選べるようにする
            if let kana = table.readingKeepingSpaces(of: segment.source) {
                list += [kana, Self.katakana(kana)]
                if !kana.contains(" "), let resolved = japaneseConverter.convert(kana: kana, context: segment.context)?.context {
                    list += japaneseConverter.alternatives(kana: kana, context: resolved)
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
