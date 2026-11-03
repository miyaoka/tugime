import Foundation

/// 確定前の 1 文節。日本語区間は変換エンジンの文節に分け、英語区間と句読点はそれぞれ 1 文節にする。候補の窓で選び直せる
public struct Clause: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        case punctuation
        /// 利用者の辞書で日本語にした、かなに読めない打鍵（Segment.Kind.word）
        case word
        /// 未確定の文字列全体を 1 つの文字種にした文節（F6〜F10）。読みは全体の読み（`wholeReading`）
        case whole

        init(_ kind: Segment.Kind) {
            switch kind {
            case .japanese: self = .japanese
            case .english: self = .english
            case .punctuation: self = .punctuation
            case .word: self = .word
            }
        }
    }

    public var kind: Kind
    /// 日本語はかな（句読点か記号をまたいでまとめた文節は、その記号と読めない英字も含む）、全体の変換は全体の読み、それ以外は打ったまま
    public var reading: String
    /// 先頭が区切りを選んだときの結果。重複は無い
    public var candidates: [String]
    public var selected: Int
    /// この文節を含む区間。同じ区間の文節は同じ値を持つ
    public var span: ClauseSpan
    /// 利用者が伸縮で範囲を決めた文節か。後ろの文節を変換し直しても、この文節の内側では切らず、両端では切る（Mozc の FIXED_BOUNDARY）
    public var fixedRange: Bool

    public init(kind: Kind, reading: String, candidates: [String], selected: Int, span: ClauseSpan, fixedRange: Bool = false) {
        self.kind = kind
        self.reading = reading
        self.candidates = candidates
        self.selected = selected
        self.span = span
        self.fixedRange = fixedRange
    }

    public var output: String { candidates[selected] }
}

/// 日英判定で決めた 1 区間
public struct ClauseSpan: Sendable, Equatable {
    /// 未確定の文字列の中で何番目の区間か
    public var index: Int
    /// 打鍵列のうちこの区間に当たる部分
    public var source: String
    /// 日本語ならかな（句読点か記号をまたいでまとめた区間は、その記号と読めない英字も含む）、それ以外は打ったまま
    public var reading: String
    /// 区間の先頭の文節を変換するときの文脈
    public var context: JapaneseContext
    /// 区切りの選択ではなく、文節の伸縮で利用者が打鍵の範囲を決めた区間か
    public var resized: Bool
    /// 文節の伸縮で句読点か記号をまたいでまとめた区間なら、まとめた部分を前から並べたもの。それ以外は空
    public var parts: [ClausePart]

    public init(index: Int, source: String, reading: String, context: JapaneseContext, resized: Bool = false, parts: [ClausePart] = []) {
        self.index = index
        self.source = source
        self.reading = reading
        self.context = context
        self.resized = resized
        self.parts = parts
    }
}

/// 句読点か記号をまたいでまとめた区間の 1 部分。まとめる前に見えていた区間の種類と形を持ち、伸縮の単位はこれで決める
public struct ClausePart: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case japanese
        case english
        /// 句読点と記号
        case mark

        var clauseKind: Clause.Kind {
            switch self {
            case .japanese: .japanese
            case .english: .english
            case .mark: .punctuation
            }
        }
    }

    public var kind: Kind
    public var source: String
    /// 日本語はかな、句読点と記号は見えていた形、英語は打ったまま
    public var reading: String
}

extension Segmenter {
    /// 区切りを選び、日本語区間を文節に分けて、文節ごとに候補の一覧を付ける。
    /// 日本語区間は、前の文字列と前の区間の表示を左の文脈にして表示の変換で文節に分ける
    public func clauses(_ input: String, leading: Leading = .start) -> [Clause] {
        clauses(of: segment(input, leading: leading), left: leading.text, firstIndex: 0, startsAtHead: true)
    }

    /// 区間を、left に続けて表示の変換にし、文節に分ける。区間の番号は firstIndex から振る。
    /// startsAtHead は最初の区間が文の頭（入力の最初か、日本語の記号にした句読点・記号の直後）か
    private func clauses(of segments: [Segment], left: String, firstIndex: Int, startsAtHead: Bool) -> [Clause] {
        zip(segments, displays(of: segments.map(ShownSpan.init), left: left, startsAtHead: startsAtHead, endsWithPendingN: false)).enumerated().flatMap { offset, pair in
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
    /// それ以外（区間の終わりを越えて伸ばすとき、英語の文節、句読点と記号の文節、伸縮で作った区間の文節）は、打鍵列の上で文節の終わりを
    /// 1 単位ずつ動かし（`unitEnd`、`unitStart`）、文節の打鍵を 1 区間として日英を判定して、後ろの打鍵は日英判定と変換をやり直す（`rebuild`）。
    /// 句読点と記号をまたぐ文節は、またいだ部分を区間に持たせ、1 つの日本語の文節として変換する（`joined`）。伸縮の単位は、その部分ごとに決める。
    /// 利用者の辞書で日本語にした打鍵の文節は伸縮しない。全体を 1 つの文字種にした文節は、区切りから文節を作り直して最初の文節を伸縮する。
    /// 伸縮できなければ元のまま返す
    /// leading は clauses より前にある、入力欄のカーソルより前の文字列
    public func resize(_ clauses: [Clause], at index: Int, by delta: Int, leading: Leading = .start) -> [Clause] {
        let clause = clauses[index]
        if clause.kind == .whole {
            let segmented = self.clauses(clause.span.source, leading: leading)
            let resized = resize(segmented, at: 0, by: delta, leading: leading)
            return resized == segmented ? clauses : resized
        }
        guard clause.kind != .word else { return clauses }
        let spans = keySpans(of: clauses)
        let keys = Array(spans.map(\.span.source).joined())
        guard let own = spans.first(where: { $0.span == clause.span }) else { return clauses }
        guard let range = keyRange(of: clauses, at: index, from: own.start) else {
            return resizeInsideSpan(clauses, at: index, by: delta, leading: leading) ?? clauses
        }
        if clause.kind == .japanese, !clause.span.resized {
            let length = clause.reading.count + delta
            guard length >= 1 else { return clauses }
            if kanaStart(of: clauses, at: index) + length <= clause.span.reading.count {
                return resizeInsideSpan(clauses, at: index, by: delta, leading: leading) ?? clauses
            }
        }
        let units = unitSpans(of: spans)
        var end = range.upperBound
        for _ in 0..<abs(delta) {
            guard let next = delta > 0 ? unitEnd(from: end, in: units) : unitStart(before: end, in: units), next > range.lowerBound else {
                return clauses
            }
            end = next
        }
        return rebuild(clauses, at: index, keys: keys, units: units, spanStart: own.start, range: range, end: end, leading: leading)
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
    private func resizeInsideSpan(_ clauses: [Clause], at index: Int, by delta: Int, leading: Leading) -> [Clause]? {
        let clause = clauses[index]
        guard clause.kind == .japanese else { return nil }
        let span = clause.span
        let spanIndices = clauses.indices.filter { clauses[$0].span == span }
        let start = kanaStart(of: clauses, at: index)
        let length = clause.reading.count + delta
        guard length >= 1, start + length <= span.reading.count else { return nil }

        let reading = String(span.reading.dropFirst(start).prefix(length))
        let context = start == 0 ? span.context : .afterWord
        let left = leading.text + clauses[..<index].map(\.output).joined()
        let resized = Clause(
            kind: .japanese,
            reading: reading,
            candidates: japaneseCandidates(reading: reading, best: japaneseConverter.display(kana: reading, context: context, left: left).text, context: context, span: span),
            selected: 0,
            span: span,
            fixedRange: true
        )
        let restKana = String(span.reading.dropFirst(start + length))
        let rest = restKana.isEmpty ? [] : japaneseClauses(
            japaneseConverter.display(kana: restKana, context: .afterWord, left: left + resized.output).clauses,
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
    /// 文節の打鍵が句読点か記号の区間をまたげば、その文節は、またいだ部分を持つ 1 つの日本語の区間にする（`joined`）
    private func rebuild(
        _ clauses: [Clause], at index: Int, keys: [Character], units: [KeySpan], spanStart: Int, range: Range<Int>, end: Int, leading: Leading
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
        let left = leading.text + before.map(\.output).joined()
        let fixedContext = context(after: before.last, keys: keys[..<range.lowerBound], leading: leading)
        let parts = parts(in: range.lowerBound..<end, of: units, keys: keys, leading: leading)
        let joinedParts = parts.count > 1 && parts.contains { $0.kind == .mark } ? parts : []
        let fixed = parts.count == 1 && parts[0].kind == .mark || !joinedParts.isEmpty
            ? joined(parts, context: fixedContext)
            : singleSpan(String(keys[range.lowerBound..<end]), context: fixedContext, preceding: keys[..<range.lowerBound].last ?? leading.text.last)
        let span: ClauseSpan
        if joinedParts.isEmpty, let (segmented, count) = segmentedSpan(fixed, before: before, start: range.lowerBound, end: end, keys: keys, leading: leading) {
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
            span = ClauseSpan(
                index: (before.last?.span.index ?? -1) + 1, source: fixed.source, reading: fixed.reading, context: fixed.context, resized: true, parts: joinedParts
            )
        }
        // 区間の 2 つ目以降の文節は、前の文節に続く形で変換する
        let clauseContext = before.last?.span == span ? JapaneseContext.afterWord : span.context
        let resized = fixed.kind == .japanese
            ? Clause(
                kind: .japanese,
                reading: fixed.reading,
                candidates: japaneseCandidates(
                    reading: fixed.reading,
                    best: japaneseConverter.display(kana: fixed.reading, context: clauseContext, left: left).text,
                    context: clauseContext,
                    span: span
                ),
                selected: 0,
                span: span,
                fixedRange: true
            )
            : Clause(kind: Clause.Kind(fixed.kind), reading: fixed.reading, candidates: candidates(for: fixed), selected: 0, span: span, fixedRange: true)
        // 句読点か記号で終わる文節の後ろは、区切り・変換の文脈・文の頭かのどれも、その記号の後として決める
        let markContinuation = continuation(afterMarkOf: resized)
        let rest = self.clauses(
            of: segment(
                String(keys[end...]),
                after: markContinuation ?? (fixed.kind == .english ? .afterEnglish : .afterJapanese),
                context: context(after: resized, keys: keys[..<end], leading: leading),
                opened: Self.unclosedOpeners(in: left + resized.output),
                preceding: keys[..<end].last ?? leading.text.last
            ),
            left: left + resized.output,
            firstIndex: span.index + 1,
            startsAtHead: markContinuation.map { $0 != .afterEnglish } ?? false
        )
        return before + [resized] + rest
    }

    /// 打鍵列の range にある、今見えている区間（まとめた区間はその部分）ごとの部分。日本語は打鍵をかなに読み直し、
    /// 句読点と記号は見えていた形のまま持つ。隣り合う日本語どうし、英語どうしはつなぐ
    private func parts(in range: Range<Int>, of units: [KeySpan], keys: [Character], leading: Leading) -> [ClausePart] {
        var parts: [ClausePart] = []
        for unit in units where unit.start < range.upperBound && range.lowerBound < unit.end {
            let start = max(unit.start, range.lowerBound)
            let source = String(keys[start..<min(unit.end, range.upperBound)])
            let part: ClausePart = switch unit.kind {
            case .japanese:
                ClausePart(
                    kind: .japanese,
                    source: source,
                    reading: source == unit.span.source
                        ? unit.span.reading
                        : Self.japaneseReading(table: table, of: source, before: keys[..<start].last ?? leading.text.last) ?? source
                )
            case .punctuation:
                ClausePart(kind: .mark, source: source, reading: unit.span.reading)
            case .english:
                ClausePart(kind: .english, source: source, reading: source)
            case .word, .whole:
                preconditionFailure("利用者の辞書で日本語にした打鍵と全体の変換の区間は、伸縮の単位にならない（unitEnd、unitStart）")
            }
            if let last = parts.last, last.kind == part.kind, part.kind != .mark {
                parts[parts.count - 1].source += part.source
                parts[parts.count - 1].reading += part.reading
            } else {
                parts.append(part)
            }
        }
        return parts
    }

    /// 部分を 1 つにした区間。句読点か記号 1 つだけなら、見えていた形の句読点の区間にする。それ以外は、かなをつないだ読みの日本語の区間にする。
    /// 句読点と記号は見えていた形にする。そのあいだに並ぶ日本語と英語の部分は、英語を含めば、打鍵の全体をかなに読み切れるとき（RomajiTable.typedKana）
    /// そのかなにする。読み切れなければ、部分ごとに日本語はかな、英語は `englishReading` で読めたもの、読めなければ打ったままにする
    private func joined(_ parts: [ClausePart], context: JapaneseContext) -> Segment {
        let source = parts.map(\.source).joined()
        if parts.count == 1, parts[0].kind == .mark {
            return Segment(kind: .punctuation, source: source, reading: parts[0].reading, output: parts[0].reading, score: 0, context: context)
        }
        var runs: [[ClausePart]] = []
        for part in parts {
            if part.kind != .mark, let last = runs.last?.last, last.kind != .mark {
                runs[runs.count - 1].append(part)
            } else {
                runs.append([part])
            }
        }
        let kana = runs.map { run in
            if run.contains(where: { $0.kind == .english }) {
                let typed = table.typedKana(of: run.map(\.source).joined())
                if typed.complete { return typed.kana }
            }
            return run.map { $0.kind == .english ? englishReading(of: $0.source) ?? $0.source : $0.reading }.joined()
        }.joined()
        return Segment(kind: .japanese, source: source, reading: kana, output: kana, score: 0, context: context)
    }

    /// 伸縮の単位を決める区間の並び。句読点か記号をまたいでまとめた区間は、まとめた部分ごとに分ける
    private func unitSpans(of spans: [KeySpan]) -> [KeySpan] {
        spans.flatMap { span in
            var start = span.start
            return span.span.parts.isEmpty ? [span] : span.span.parts.map { part in
                defer { start += part.source.count }
                let piece = ClauseSpan(index: span.span.index, source: part.source, reading: part.reading, context: span.span.context, resized: true)
                return KeySpan(span: piece, kind: part.kind.clauseKind, start: start)
            }
        }
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
    /// 次のかなと合わせる）、英語の区間では 1 打鍵（打ったままの句読点を含む）、句読点と記号の区間では区間の全体。
    /// 利用者の辞書で日本語にした打鍵の区間と、打鍵列の終わりでは nil
    private func unitEnd(from position: Int, in spans: [KeySpan]) -> Int? {
        guard let next = spans.first(where: { $0.start <= position && position < $0.end }) else { return nil }
        switch next.kind {
        case .word, .whole:
            return nil
        case .punctuation:
            return next.end
        case .english:
            return position + 1
        case .japanese:
            return table.readings(from: position - next.start, in: Array(next.span.source)).first.map { next.start + $0.end }
        }
    }

    /// 打鍵列の position で終わる、文節が手放す 1 単位の始まり。日本語の区間では区間の始まりから読み切れる綴りの境目のうち
    /// position より前で最も後ろのもの、英語の区間では 1 打鍵前、句読点と記号の区間では区間の始まり。
    /// 利用者の辞書で日本語にした打鍵の区間と、打鍵列の始まりでは nil
    private func unitStart(before position: Int, in spans: [KeySpan]) -> Int? {
        guard let span = spans.first(where: { $0.start < position && position <= $0.end }) else { return nil }
        switch span.kind {
        case .word, .whole:
            return nil
        case .punctuation:
            return span.start
        case .english:
            return position - 1
        case .japanese:
            return table.readings(from: 0, in: Array(span.span.source)).map { span.start + $0.end }.filter { $0 < position }.max() ?? span.start
        }
    }

    /// 文節を変換する文脈。英語の後は前の語に続く形（数字の後は助数詞）、日本語の後は前の文節に続く形、
    /// 句読点と記号の後（句読点か記号で終わるまとめた文節の後を含む）は区切りの選択と同じ形
    private func context(after previous: Clause?, keys: ArraySlice<Character>, leading: Leading) -> JapaneseContext {
        guard let previous else { return leading.japaneseContext }
        if let mark = continuation(afterMarkOf: previous) { return mark.japaneseContext }
        switch previous.kind {
        case .english:
            return Self.context(after: keys)
        case .japanese, .word:
            return .afterWord
        case .punctuation:
            preconditionFailure("句読点と記号の文節の後ろは continuation(afterMarkOf:) が決める")
        case .whole:
            preconditionFailure("全体の変換の文節は 1 つだけで、後ろに文節を持たない")
        }
    }

    /// 文節が句読点か記号で終わるなら（句読点と記号の文節と、句読点か記号で終わるまとめた文節）、その後ろの評価のしかた。
    /// 区切り・変換の文脈・後ろが文の頭かは、どれもこの値から決める
    private func continuation(afterMarkOf clause: Clause) -> Continuation? {
        if clause.kind == .punctuation { return Self.continuation(after: clause.span.source, mark: clause.span.reading) }
        guard let last = clause.span.parts.last, last.kind == .mark else { return nil }
        return Self.continuation(after: last.source, mark: last.reading)
    }

    /// 区間ごとの文節を、left に続けて前から順に表示の変換にし直す。日本語区間は文節に分け直し、それ以外の区間は選んだ文字列のまま残す。
    /// 日本語区間の表記は区間の全体を 1 回変換して決め、利用者が伸縮で範囲を決めた文節（fixedRange）は、その範囲のまま残す（`keepingFixedRanges`）
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
            let startsSentence = continuation(afterMarkOf: group[group.count - 1]).map { $0 != .afterEnglish } ?? false
            return switch group[0].kind {
            case .japanese: ShownSpan.japanese(kana: group[0].span.reading, context: group[0].span.context, startsSentence: startsSentence)
            case .punctuation: ShownSpan.mark(group.map(\.output).joined(), startsSentence: startsSentence)
            case .english, .word, .whole: ShownSpan.fixed(group.map(\.output).joined())
            }
        }
        // 伸縮した区間より後ろの文節だけなので、最初の文節は入力の最初ではない
        return zip(groups, displays(of: spans, left: left, startsAtHead: false, endsWithPendingN: false)).flatMap { group, display in
            display.map { keepingFixedRanges(of: group, in: $0) } ?? group
        }
    }

    /// 日本語区間の文節 group を、区間の表示 shown の文節にする。group に利用者が範囲を決めた文節があれば、その範囲の内側では切らず、
    /// 両端で切る。ほかの区切りは表示の変換が決めたものを使う。表記は shown を読みの位置で切るので、文節の表記をつなぐと shown の表記になる。
    /// 表記と読みの対応で位置が決まらない区切りは切らない（ReadingAlignment）
    private func keepingFixedRanges(of group: [Clause], in shown: JapaneseDisplay) -> [Clause] {
        let span = group[0].span
        var start = 0
        var fixed: [Range<Int>] = []
        for clause in group {
            if clause.fixedRange { fixed.append(start..<(start + clause.reading.count)) }
            start += clause.reading.count
        }
        guard !fixed.isEmpty else { return japaneseClauses(shown.clauses, context: span.context, in: span) }
        var shownCuts: [Int] = []
        for clause in shown.clauses.dropLast() { shownCuts.append((shownCuts.last ?? 0) + clause.reading.count) }
        let edges = fixed.flatMap { [$0.lowerBound, $0.upperBound] }.filter { $0 > 0 && $0 < span.reading.count }
        let cuts = Set(shownCuts.filter { cut in !fixed.contains { $0.lowerBound < cut && cut < $0.upperBound } } + edges).sorted()
        let parts = ReadingAlignment(text: shown.text, reading: span.reading)?.clauses(cutAt: cuts) ?? [JapaneseClause(reading: span.reading, text: shown.text)]
        var position = 0
        return japaneseClauses(parts, context: span.context, in: span).map { clause in
            defer { position += clause.reading.count }
            var kept = clause
            kept.fixedRange = fixed.contains(position..<(position + clause.reading.count))
            return kept
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

    private func japaneseCandidates(reading: String, best: String, context: JapaneseContext, span: ClauseSpan) -> [String] {
        var list = [best]
        // 区間全体の文節では、打ったままの綴りが区切りの選択で英語になりうるなら最良のすぐ後に、そうでなければ最後に置く
        let whole = reading == span.reading
        let typedCanBeEnglish = whole && !prefersJapanese(span.source, readable: true)
        if typedCanBeEnglish { list.append(span.source) }
        list += japaneseConverter.alternatives(kana: reading, context: context)
        list += [reading, Self.katakana(reading)]
        if whole, !typedCanBeEnglish { list.append(span.source) }
        return Self.unique(list)
    }

    private func candidates(for segment: Segment) -> [String] {
        var list: [String] = [segment.output]
        switch segment.kind {
        case .punctuation:
            // 日本語の記号と打ったままの両方を選べる。組の開き括弧に合わせて打ったままの形にした閉じ括弧もある
            list.append(segment.source)
            if let mark = segment.source.first.flatMap({ Self.punctuation[$0] }) { list.append(mark) }
        case .word:
            list += (typedJapaneseWords[segment.source] ?? []) + [segment.source] + typedForms(of: segment.source, context: segment.context)
        case .japanese:
            preconditionFailure("日本語区間は japaneseClauses で文節に分ける")
        case .english:
            // 利用者の辞書で表記を替えたときは、打ったままの綴りをすぐ後に置く
            list.append(segment.source)
            // 区間の末尾で打ったままにした句読点は、日本語の記号を選べる（github. の . を 。 に）。途中の句読点（vue.js）は変えない
            let trailing = segment.output.reversed().prefix { Self.punctuation[$0] != nil }.count
            let marked: [String] = trailing > 0
                ? [String(segment.output.dropLast(trailing)) + segment.output.suffix(trailing).map { Self.punctuation[$0]! }.joined()]
                : []
            let forms = typedForms(of: segment.source, context: segment.context)
            list += [forms[0]] + marked + forms.dropFirst()
        }
        return Self.unique(list)
    }

    /// 打ったままの綴りを表記にする文節（英語の区間と、利用者の辞書で日本語にした読めない打鍵の語）で、打ったままの綴りの後に並べる候補。
    /// 全角の英字と、語を `englishReading` でかなにできればそのかな・カタカナ・変換
    private func typedForms(of source: String, context: JapaneseContext) -> [String] {
        var list = [Self.text(source, .fullwidthRoman)]
        guard let kana = englishReading(of: source) else { return list }
        list += [kana, Self.katakana(kana)]
        // 変換エンジンには前後の空白を除いた 1 語の読みを渡し、候補に空白を付け直す
        let head = String(kana.prefix { $0 == " " })
        let tail = String(kana.reversed().prefix { $0 == " " })
        let word = kana.trimmingCharacters(in: .init(charactersIn: " "))
        if !word.contains(" ") {
            let resolved = japaneseConverter.convert(kana: word, context: context).context
            list += japaneseConverter.alternatives(kana: word, context: resolved).map { head + $0 + tail }
        }
        return list
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen: Set<String> = []
        return list.filter { seen.insert($0).inserted }
    }

    private static func katakana(_ hiragana: String) -> String {
        hiragana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? hiragana
    }
}
