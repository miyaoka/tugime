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
    /// 区切りを選び、日本語区間を文節に分けて、文節ごとに候補の一覧を付ける
    public func clauses(_ input: String, leading: Leading = .start) -> [Clause] {
        let segments = segment(input, leading: leading)
        return segments.enumerated().flatMap { index, segment in
            // 句読点の直後は文頭、入力の先頭は入力欄の前の文脈、それ以外は前の語に続く形として変換する
            let context: JapaneseContext = index == 0 ? leading.japaneseContext
                : segments[index - 1].kind == .punctuation ? .start
                : Self.context(after: segments[index - 1].source)
            guard segment.kind == .japanese else {
                let span = ClauseSpan(index: index, source: segment.source, reading: segment.reading, context: context)
                return [Clause(kind: segment.kind, reading: segment.reading, candidates: candidates(for: segment, context: context), selected: 0, span: span)]
            }
            // カーソルの前に続く区間は、区切りを選んだときに読んだ形（文頭か前の語に続く形）で文節と候補を作る。区切りはこの区間を変換できたときだけ日本語にする
            guard let resolved = japaneseConverter.convert(kana: segment.reading, context: context)?.context else {
                preconditionFailure("日本語区間を変換できない: \(segment.reading)")
            }
            return japaneseClauses(from: 0, in: ClauseSpan(index: index, source: segment.source, reading: segment.reading, context: resolved))
        }
    }

    /// 日本語の文節を 1 かなずつ伸ばす（delta が正）・縮める（負）。区間の外へは伸ばさず、1 かなより短くしない。
    /// 伸縮した文節の後ろにある同じ区間の残りは、文節に分け直して変換する。伸縮できなければ元のまま返す
    public func resize(_ clauses: [Clause], at index: Int, by delta: Int) -> [Clause] {
        let clause = clauses[index]
        guard clause.kind == .japanese else { return clauses }
        let span = clause.span
        let spanIndices = clauses.indices.filter { clauses[$0].span == span }
        let start = clauses[spanIndices.first!..<index].map(\.reading.count).reduce(0, +)
        let length = clause.reading.count + delta
        guard length >= 1, start + length <= span.reading.count else { return clauses }

        let reading = String(span.reading.dropFirst(start).prefix(length))
        let context = start == 0 ? span.context : .afterWord
        let resized = Clause(
            kind: .japanese,
            reading: reading,
            candidates: japaneseCandidates(reading: reading, best: nil, context: context, span: span),
            selected: 0,
            span: span
        )
        let rest = start + length < span.reading.count ? japaneseClauses(from: start + length, in: span) : []
        return Array(clauses[..<index]) + [resized] + rest + Array(clauses[(spanIndices.last! + 1)...])
    }

    /// index の文節までを確定するときの、確定する文字列、残りの文節、残りの打鍵列。
    /// 日本語区間の途中で切るときは、残りをその位置から始まる区間として持ち直す。切る位置に当たる打鍵が決まらなければ nil
    public func commit(_ clauses: [Clause], through index: Int) -> (text: String, rest: [Clause], keys: String)? {
        let text = clauses[...index].map(\.output).joined()
        var rest = Array(clauses[(index + 1)...])
        if let next = rest.first, next.span == clauses[index].span {
            let span = next.span
            let done = clauses[...index].filter { $0.span == span }.map(\.reading.count).reduce(0, +)
            guard let (_, tail) = table.split(span.source, kana: span.reading, atKana: done) else { return nil }
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

    /// 区間の読みのうち offset かな目から後ろを、変換エンジンの文節に分ける
    private func japaneseClauses(from offset: Int, in span: ClauseSpan) -> [Clause] {
        let kana = String(span.reading.dropFirst(offset))
        let context = offset == 0 ? span.context : .afterWord
        let parts = japaneseConverter.convert(kana: kana, context: context)?.clauses ?? [JapaneseClause(reading: kana, text: kana)]
        return parts.enumerated().map { index, part in
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

    private func candidates(for segment: Segment, context: JapaneseContext) -> [String] {
        var list: [String] = [segment.output]
        switch segment.kind {
        case .punctuation:
            list.append(segment.source)
        case .japanese:
            preconditionFailure("日本語区間は japaneseClauses で文節に分ける")
        case .english:
            // 英語と判定した区間も、綴りの表で読めればかなを選べるようにする
            if let kana = table.reading(of: segment.source) {
                list += [kana, Self.katakana(kana)]
                if let resolved = japaneseConverter.convert(kana: kana, context: context)?.context {
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
