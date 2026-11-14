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
    /// 利用者が伸縮で範囲を決め、その範囲がまだ保たれている文節か。作り直すときに範囲を守るかは `keepingFixedRanges` が決める
    public var fixedRange: Bool
    /// 利用者が選んだ表記。候補の窓・F6〜F10・組になる括弧の形で先頭以外の候補を選ぶと付き、先頭の候補を選び直すと外れる。
    /// 作り直した文節では、選んだ表記が先頭の候補になっても付けたまま残す。作り直すときに範囲を守るかは `keepingFixedRanges` が決める
    public internal(set) var fixedValue: String?

    public init(kind: Kind, reading: String, candidates: [String], selected: Int, span: ClauseSpan, fixedRange: Bool = false) {
        self.kind = kind
        self.reading = reading
        self.candidates = candidates
        self.selected = selected
        self.span = span
        self.fixedRange = fixedRange
    }

    public var output: String { candidates[selected] }

    /// 作り直すときに範囲を守る文節か
    var kept: Bool { fixedRange || fixedValue != nil }

    /// 空白だけの文節か。空白は語を区切る印で、変換して選ぶ対象ではない
    var isSpace: Bool { kind == .english && reading.allSatisfy { $0 == " " } }

    /// 選ぶ文節を focus から step（-1 で左、1 で右）の向きに、空白だけの文節を飛ばして次の文節へ移した位置。
    /// 端から先へ移すと反対の端から数える。打鍵列は空白で始まらず、文節までの確定も空白だけを残さない（`Segmenter.commit(_:through:)`）ので、
    /// 空白だけでない文節が必ずある
    public static func focus(_ focus: Int, movedBy step: Int, in clauses: [Clause]) -> Int {
        var index = focus
        for _ in clauses.indices {
            index = (index + step + clauses.count) % clauses.count
            if !clauses[index].isSpace { return index }
        }
        preconditionFailure("空白だけの文節しか無い: \(clauses.map(\.reading))")
    }

    /// 候補 text の番号。候補に無ければ末尾に足す
    mutating func candidateIndex(adding text: String) -> Int {
        if let index = candidates.firstIndex(of: text) { return index }
        candidates.append(text)
        return candidates.count - 1
    }

    /// 作り直した文節で、利用者が選んでいた表記 text を選び直す
    mutating func fix(_ text: String) {
        selected = candidateIndex(adding: text)
        fixedValue = text
    }
}

/// 作り直すときに守る文節。range は読み（打鍵の上で扱うときは打鍵）の中の範囲。
/// fixedRange は利用者が伸縮で範囲を決めたか、fixedValue は利用者が選んだ表記
struct KeptClause: Equatable {
    var range: Range<Int>
    var fixedRange: Bool
    var fixedValue: String?

    init(range: Range<Int>, of clause: Clause) {
        self.range = range
        self.fixedRange = clause.fixedRange
        self.fixedValue = clause.fixedValue
    }

    init(range: Range<Int>, fixedRange: Bool, fixedValue: String?) {
        self.range = range
        self.fixedRange = fixedRange
        self.fixedValue = fixedValue
    }

    func shifted(by offset: Int) -> KeptClause {
        KeptClause(range: (range.lowerBound + offset)..<(range.upperBound + offset), fixedRange: fixedRange, fixedValue: fixedValue)
    }

    func moved(to range: Range<Int>) -> KeptClause {
        KeptClause(range: range, fixedRange: fixedRange, fixedValue: fixedValue)
    }

    /// 作り直した文節 clause に、守る範囲と選んだ表記を付け直す
    func apply(to clause: inout Clause) {
        clause.fixedRange = fixedRange
        if let fixedValue { clause.fix(fixedValue) }
    }
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
        clauses(of: segment(input, leading: leading), left: leading.text, firstIndex: 0, startsAtHead: true, endsInput: true)
    }

    /// 空白で終わる打鍵列で、末尾の空白の前の 1 語を、今の区切りと反対の言語の 1 区間・1 文節にして文節に分ける（空白の後の Space）。
    /// 語は、その前の空白（無ければ打鍵列の先頭）から末尾の空白までの打鍵。今の区切りで語の打鍵がすべて英語の区間にあれば日本語に、
    /// 日本語を含めば英語にする。語より前は語の手前までを入力として区切り、末尾の空白は英語の区間にする。
    /// 語の文節の候補は、反対の言語の表記を先頭に、打っている途中に見えていた語の表示を 2 番目に置くので、候補を 1 つ進めると見えていた表示に戻る。
    /// 返す focus は語の文節の位置。語が無いか、句読点か記号の打鍵を含むか、数字だけか（数は日本語でも英語でもない）、
    /// 日本語にするのに読み切れなければ nil
    public func clausesFlippingLastWord(_ input: String, leading: Leading = .start) -> (clauses: [Clause], focus: Int)? {
        let chars = Array(input)
        let trailing = chars.reversed().prefix { $0 == " " }.count
        guard trailing > 0 else { return nil }
        let wordEnd = chars.count - trailing
        let wordStart = chars[..<wordEnd].lastIndex(of: " ").map { $0 + 1 } ?? 0
        guard wordStart < wordEnd else { return nil }
        let word = String(chars[wordStart..<wordEnd])
        // 句読点と記号の打鍵は入力を切るので、それを含む語は 1 区間にできない
        let wordChars = Array(word)
        guard wordChars.indices.allSatisfy({ Self.punctuation[wordChars[$0]] == nil && Self.symbol(at: $0, in: wordChars) == nil }),
              !Self.isNumber(word)
        else { return nil }

        // 空白は入力を切るので、語の打鍵の範囲は区間の切れ目と一致する。語の区間の種類と、打っている途中に見えていた語の表示を、
        // 打っている途中の表示（liveDisplay）と同じ経路で取る
        let segments = segment(input, leading: leading)
        var keyStart = 0
        var wordIsEnglish = true
        var shown = ""
        _ = displays(of: segments.map(ShownSpan.init), left: leading.text, startsAtHead: true, endsInput: true, endsWithPendingN: false) { index, display, _ in
            let segment = segments[index]
            let text = display?.text ?? segment.output
            if (wordStart..<wordEnd).contains(keyStart) {
                wordIsEnglish = wordIsEnglish && segment.kind == .english
                shown += text
            }
            keyStart += segment.source.count
            return (result: (), shown: text)
        }

        let before = segment(String(chars[..<wordStart]), leading: leading)
        // 語の前は空白の区間で終わり、その区間が後ろを評価する文脈を持つ
        let context = before.last?.context ?? leading.japaneseContext
        let preceding = wordStart > 0 ? chars[wordStart - 1] : leading.text.last
        guard let flipped = span(word, as: wordIsEnglish ? .japanese : .english, context: context, preceding: preceding) else { return nil }
        let spaces = Self.spaceSegment(String(chars[wordEnd...]), context: Self.context(after: chars[..<wordEnd]))
        // 日本語にした語は、表示の変換が文節に分けても 1 文節に保つ
        let fixed = wordIsEnglish ? [KeptClause(range: wordStart..<wordEnd, fixedRange: true, fixedValue: nil)] : []
        var clauses = clauses(of: before + [flipped, spaces], left: leading.text, firstIndex: 0, startsAtHead: true, endsInput: true, fixedKeys: fixed)
        guard let focus = clauses.firstIndex(where: { $0.span.index == before.count }) else {
            preconditionFailure("入れ替えた語の文節が無い: \(input)")
        }
        let flippedText = clauses[focus].candidates[0]
        clauses[focus].candidates = [flippedText] + [shown].filter { $0 != flippedText } + clauses[focus].candidates.dropFirst().filter { $0 != shown }
        return (clauses, focus)
    }

    /// 区間を、left に続けて表示の変換にし、文節に分ける。区間の番号は firstIndex から振る。
    /// startsAtHead は最初の区間が文の頭（入力の最初か、日本語の記号にした句読点・記号の直後）か。endsInput は最後の区間が入力の終わりか（`displays`）。
    /// fixedKeys は利用者が範囲を決めたか表記を選んだ文節の打鍵の範囲（segments の打鍵の始まりからの位置）。日本語区間の中に丸ごと収まり、
    /// 両端がその区間の読みのかなの境目に当たるものを守る（`keepingFixedRanges`）。英語・句読点と記号の区間は、打鍵の範囲が区間と同じものの
    /// 印と選んだ表記を付け直す。後ろの区間は、選んだ表記を含めて表示した文字列を左の文脈にして変換する
    private func clauses(of segments: [Segment], left: String, firstIndex: Int, startsAtHead: Bool, endsInput: Bool, fixedKeys: [KeptClause] = []) -> [Clause] {
        var keyStart = 0
        return displays(of: segments.map(ShownSpan.init), left: left, startsAtHead: startsAtHead, endsInput: endsInput, endsWithPendingN: false) { offset, display, shown in
            let segment = segments[offset]
            defer { keyStart += segment.source.count }
            let keys = keyStart..<(keyStart + segment.source.count)
            let span = ClauseSpan(index: firstIndex + offset, source: segment.source, reading: segment.reading, context: segment.context)
            let spanClauses: [Clause]
            if let display {
                let fixed = fixedKeys.compactMap { kept -> KeptClause? in
                    guard keys.lowerBound <= kept.range.lowerBound, kept.range.upperBound <= keys.upperBound,
                          let lower = kanaPosition(atKey: kept.range.lowerBound - keys.lowerBound, in: span),
                          let upper = kanaPosition(atKey: kept.range.upperBound - keys.lowerBound, in: span), lower < upper
                    else { return nil }
                    return kept.moved(to: lower..<upper)
                }
                spanClauses = keepingFixedRanges(fixed, in: display, reading: span.reading, context: span.context, span: span, left: shown)
            } else {
                var clause = Clause(kind: Clause.Kind(segment.kind), reading: segment.reading, candidates: candidates(for: segment), selected: 0, span: span)
                fixedKeys.first { $0.range == keys }?.apply(to: &clause)
                spanClauses = [clause]
            }
            return (result: spanClauses, shown: spanClauses.map(\.output).joined())
        }.flatMap { $0 }
    }

    /// 区間の打鍵の先頭 key 打鍵に当たる、読みのかなの位置。綴りの途中に当たれば nil
    private func kanaPosition(atKey key: Int, in span: ClauseSpan) -> Int? {
        (0...span.reading.count).first { splitSource(of: span, atKana: $0)?.head.count == key }
    }

    /// 文節を伸ばす（delta が正）・縮める（負）。区切りの選択が決めた日本語の区間の中では、区間の読みのかなの上で 1 かなずつ伸縮し、
    /// 1 かなより短くしない（`resizeInsideSpan`）。文節の始まりが 1 つの綴りの途中にあって打鍵を切り出せないときも同じにする。
    /// それ以外（区間の終わりを越えて伸ばすとき、英語の文節、句読点と記号の文節、伸縮で作った区間の文節）は、打鍵列の上で文節の終わりを
    /// 1 単位ずつ動かし（`unitEnd`、`unitStart`）、文節の打鍵を 1 区間として日英を判定して、後ろの打鍵は日英判定と変換をやり直す（`rebuild`）。
    /// 後ろに利用者が伸縮で作った区間があれば、日英判定をやり直すのはその手前までで、その区間から後ろは区間を残して変換だけをやり直す。
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
        let end = start + length
        let restKana = String(span.reading.dropFirst(end))
        let rest = restKana.isEmpty ? [] : keepingFixedRanges(
            fixedRanges(after: index, in: spanIndices.map { clauses[$0] }, from: end, spanStart: spanIndices[0], shrunk: delta < 0),
            in: japaneseConverter.display(kana: restKana, context: .afterWord, left: left + resized.output),
            reading: restKana,
            context: .afterWord,
            span: span,
            left: left + resized.output
        )
        // 区間の中での伸縮なので、後ろの区間の直前は記号で終わらない日本語の文節で、文の頭ではない
        let later = redisplay(Array(clauses[(spanIndices.last! + 1)...]), left: left + ([resized] + rest).map(\.output).joined(), startsAtHead: false)
        return Array(clauses[..<index]) + [resized] + rest + later
    }

    /// 区間の中で index の文節を伸縮して、文節の終わりが区間の読みの end になったとき、残りの読み（end から後ろ）の中で守る、
    /// 利用者が範囲を決めたか候補を選んだ文節。spanClauses は区間の文節を前から並べたもの、spanStart は clauses の中でのその先頭の位置。
    /// 伸ばして読みを取り込まれた文節は end より前に始まるので守らない。縮めた（shrunk）ときは、手放した読みに続くすぐ後ろの文節も守らない
    private func fixedRanges(after index: Int, in spanClauses: [Clause], from end: Int, spanStart: Int, shrunk: Bool) -> [KeptClause] {
        var position = 0
        var later: [(kept: KeptClause, isKept: Bool)] = []
        for (offset, clause) in spanClauses.enumerated() {
            defer { position += clause.reading.count }
            guard spanStart + offset > index, position >= end else { continue }
            later.append((KeptClause(range: position..<(position + clause.reading.count), of: clause), clause.kept))
        }
        return later.dropFirst(shrunk ? 1 : 0).filter(\.isKept).map { $0.kept.shifted(by: -end) }
    }

    /// index の文節の終わりを打鍵列の end にして後ろの打鍵を作り直すとき、守る、利用者が範囲を決めたか候補を選んだ文節（打鍵の範囲は end からの位置）。
    /// 区間の中での伸縮（`fixedRanges`）と同じく、縮めた（shrunk）ときは手放した打鍵に続くすぐ後ろの文節を守らない。
    /// すぐ後ろの文節は、打鍵の範囲が決まらなくても位置で数える。打鍵の範囲が決まらない文節は守らない
    private func fixedKeyRanges(after index: Int, in clauses: [Clause], from end: Int, shrunk: Bool) -> [KeptClause] {
        let spans = keySpans(of: clauses)
        return clauses.indices.dropFirst(index + 1).compactMap { i in
            guard clauses[i].kept, !(shrunk && i == index + 1),
                  let own = spans.first(where: { $0.span == clauses[i].span }),
                  let range = keyRange(of: clauses, at: i, from: own.start), range.lowerBound >= end
            else { return nil }
            return KeptClause(range: range, of: clauses[i]).shifted(by: -end)
        }
    }

    /// index の文節を打鍵列の range.lowerBound..<end にして、その打鍵を 1 区間として日英を判定する。
    /// 後ろの打鍵は、その文節の表示を左の文脈にして日英判定と変換をやり直す。後ろに利用者が伸縮で作った区間があれば（`laterResizedSpan`）、
    /// 日英判定をやり直すのはその手前までにし、その手前を入力の終わりとして区切る。その区間から後ろは、区間を残し、番号と先頭の文脈を付け直して
    /// 変換だけをやり直す（`redisplay`）。range は文節の今の打鍵、spanStart はその区間の始まり。
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
        let shrunk = end < range.upperBound
        // 後ろの打鍵を keyEnd の手前まで日英判定からやり直す。keyEnd が打鍵列の終わりでなければ、その手前は入力の終わりではない
        let judge = { (keyEnd: Int) in
            self.clauses(
                of: self.segment(
                    String(keys[end..<keyEnd]),
                    after: markContinuation ?? (fixed.kind == .english ? .afterEnglish : .afterJapanese),
                    context: self.context(after: resized, keys: keys[..<end], leading: leading),
                    opened: Self.unclosedOpeners(in: left + resized.output),
                    preceding: keys[..<end].last ?? leading.text.last
                ),
                left: left + resized.output,
                firstIndex: span.index + 1,
                startsAtHead: markContinuation.map { $0 != .afterEnglish } ?? false,
                endsInput: keyEnd == keys.count,
                fixedKeys: self.fixedKeyRanges(after: index, in: clauses, from: end, shrunk: shrunk)
            )
        }
        // 後ろに利用者が伸縮で作った区間があれば、日英判定をやり直すのはその手前までにし、その区間から後ろは区間をそのまま残す
        guard let kept = laterResizedSpan(after: index, in: clauses, from: end, shrunk: shrunk) else {
            return before + [resized] + judge(keys.count)
        }
        let judged = judge(kept.keyStart)
        let shownBefore = left + resized.output + judged.map(\.output).joined()
        // 残す区間の後ろの閉じ丸括弧は、手前の開き丸括弧の形で決めてある。手前の閉じていない開き丸括弧の並びが変わったら残さない
        guard Self.unclosedOpeners(in: shownBefore) == Self.unclosedOpeners(in: leading.text + clauses[..<kept.clause].map(\.output).joined()) else {
            return before + [resized] + judge(keys.count)
        }
        var tail = renumbered(Array(clauses[kept.clause...]), from: (judged.last?.span.index ?? span.index) + 1)
        // 残す区間の前は作り直したので、残す日本語区間の先頭を変換する文脈と、文の頭かを、作り直した前の文節から決め直す。
        // 英語・句読点と記号の区間は、表示を選んだ文字列のまま残すので、文脈を付け直さない
        let previous = judged.last ?? resized
        let first = tail[0].span
        if tail[0].kind == .japanese {
            let keptContext = context(after: previous, keys: keys[..<kept.keyStart], leading: leading)
            for i in tail.indices where tail[i].span == first {
                tail[i].span.context = keptContext
            }
        }
        return before + [resized] + judged + redisplay(
            tail, left: shownBefore, startsAtHead: continuation(afterMarkOf: previous).map { $0 != .afterEnglish } ?? false
        )
    }

    /// index の文節の終わりを打鍵列の end にして後ろの打鍵を作り直すとき、そのまま残す、利用者が伸縮で作った最初の区間。
    /// 区間の打鍵の始まり（keyStart）と、clauses の中での区間の最初の文節（clause）。end より前に始まる区間（伸ばして取り込まれた区間）は残さない。
    /// 縮めた（shrunk）ときは、手放した打鍵に続くすぐ後ろの文節の区間も残さない。伸縮した文節のもとの区間は数えない
    private func laterResizedSpan(after index: Int, in clauses: [Clause], from end: Int, shrunk: Bool) -> (keyStart: Int, clause: Int)? {
        let spans = keySpans(of: clauses)
        let next = index + 1
        return clauses.indices.dropFirst(next).lazy.compactMap { i -> (keyStart: Int, clause: Int)? in
            let span = clauses[i].span
            guard span.resized, span != clauses[index].span, clauses[i - 1].span != span,
                  !(shrunk && clauses[next].span == span),
                  let start = spans.first(where: { $0.span == span })?.start, start >= end
            else { return nil }
            return (start, i)
        }.first
    }

    /// 文節の区間の番号を、区間ごとに first から振り直す。残した区間の番号が、日英判定をやり直した区間の番号と重ならないようにする
    private func renumbered(_ clauses: [Clause], from first: Int) -> [Clause] {
        var index = first - 1
        var last: ClauseSpan?
        return clauses.map { clause in
            var copy = clause
            if clause.span != last { index += 1 }
            last = clause.span
            copy.span.index = index
            return copy
        }
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
    /// 日本語区間の表記は区間の全体を 1 回変換して決め、利用者が範囲を決めたか表記を選んだ文節は、その範囲と表記のまま残す（`keepingFixedRanges`）。
    /// 後ろの区間は、選んだ表記を含めて表示した文字列を左の文脈にして変換する。
    /// startsAtHead は最初の区間が文の頭（日本語の記号にした句読点・記号の直後）か。伸縮した区間より後ろの文節を入力の終わりまで渡すので、入力の最初ではなく、
    /// 最後の区間は入力の終わりである
    private func redisplay(_ clauses: [Clause], left: String, startsAtHead: Bool) -> [Clause] {
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
            case .punctuation: ShownSpan.other(startsSentence: startsSentence)
            case .english, .word, .whole: ShownSpan.other(startsSentence: false)
            }
        }
        return displays(of: spans, left: left, startsAtHead: startsAtHead, endsInput: true, endsWithPendingN: false) { index, display, shown in
            let group = groups[index]
            let spanClauses = display.map { converted in
                var start = 0
                var fixed: [KeptClause] = []
                for clause in group {
                    if clause.kept { fixed.append(KeptClause(range: start..<(start + clause.reading.count), of: clause)) }
                    start += clause.reading.count
                }
                return keepingFixedRanges(fixed, in: converted, reading: group[0].span.reading, context: group[0].span.context, span: group[0].span, left: shown)
            } ?? group
            return (result: spanClauses, shown: spanClauses.map(\.output).joined())
        }.flatMap { $0 }
    }

    /// 読み reading の表示 shown を文節に分ける。fixed は利用者が範囲を決めたか表記を選んだ文節の、reading の中の範囲と印と選んだ表記。
    /// 範囲の両端を shown の表記の上で切れるなら（`ShownPieces`）、その範囲の内側では切らず、両端で切り、印と選んだ表記を付け直す。
    /// 切れない範囲は、表記を選んでいなければ守らない。表記を選んでいれば、その文節の前後で読みを分けて変換し、選んだ表記を残す（`splitting`）。
    /// ほかの区切りは表示の変換の文節の境目をそのまま使う。範囲を切るときの表記は shown の文節を切るかつなぐだけなので、文節の表記をつなぐと shown の表記になる。
    /// context は先頭の文節を変換した文脈、left は reading より前に表示している文字列
    private func keepingFixedRanges(
        _ fixed: [KeptClause], in shown: JapaneseDisplay, reading: String, context: JapaneseContext, span: ClauseSpan, left: String
    ) -> [Clause] {
        let pieces = ShownPieces(shown.clauses)
        let inner = { (position: Int) in position > 0 && position < reading.count }
        let cuttable = { (kept: KeptClause) in
            [kept.range.lowerBound, kept.range.upperBound].filter(inner).allSatisfy(pieces.canCut(atReading:))
        }
        if let chosen = fixed.first(where: { $0.fixedValue != nil && !cuttable($0) }) {
            return splitting(reading, around: chosen, keeping: fixed, context: context, span: span, left: left)
        }
        let kept = fixed.filter(cuttable)
        guard !kept.isEmpty else { return japaneseClauses(shown.clauses, context: context, in: span) }
        let edges = kept.flatMap { [$0.range.lowerBound, $0.range.upperBound] }.filter(inner)
        let cuts = Set(pieces.bounds.filter { cut in inner(cut) && !kept.contains { $0.range.lowerBound < cut && cut < $0.range.upperBound } } + edges).sorted()
        let parts = pieces.clauses(cutAt: cuts)
        var position = 0
        return japaneseClauses(parts, context: context, in: span).map { clause in
            defer { position += clause.reading.count }
            var marked = clause
            kept.first { $0.range == position..<(position + clause.reading.count) }?.apply(to: &marked)
            return marked
        }
    }

    /// 表示の変換の文節を、読みの位置で切り直す。変換の文節の境目では常に切れ、境目の表記の位置は変換が返したまま使う。
    /// 文節の内側は、その文節の表記と読みの対応（ReadingAlignment）で表記の位置が決まるときだけ切れる
    private struct ShownPieces {
        let clauses: [JapaneseClause]
        /// 変換の文節の境目の読みの位置。0 と読みの終わりを含む
        let bounds: [Int]

        init(_ clauses: [JapaneseClause]) {
            self.clauses = clauses
            var bounds = [0]
            for clause in clauses { bounds.append(bounds.last! + clause.reading.count) }
            self.bounds = bounds
        }

        func canCut(atReading position: Int) -> Bool {
            if bounds.contains(position) { return true }
            guard let i = bounds.lastIndex(where: { $0 < position }) else { return false }
            return ReadingAlignment(text: clauses[i].text, reading: clauses[i].reading)?.canCut(atReading: position - bounds[i]) == true
        }

        /// 読みの位置 cuts（0 と読みの終わりを含まない昇順。どれも canCut で切れる位置）で切った文節。
        /// cuts に無い変換の境目では切らず、両側の表記をつなぐ。表記をつなぐと、変換の文節の表記をつないだものになる
        func clauses(cutAt cuts: [Int]) -> [JapaneseClause] {
            let pieces = clauses.indices.flatMap { i -> [JapaneseClause] in
                let inside = cuts.filter { bounds[i] < $0 && $0 < bounds[i + 1] }.map { $0 - bounds[i] }
                guard !inside.isEmpty else { return [clauses[i]] }
                return ReadingAlignment(text: clauses[i].text, reading: clauses[i].reading)!.clauses(cutAt: inside)
            }
            var merged: [JapaneseClause] = []
            var position = 0
            for piece in pieces {
                if let last = merged.last, !cuts.contains(position) {
                    merged[merged.count - 1] = JapaneseClause(reading: last.reading + piece.reading, text: last.text + piece.text)
                } else {
                    merged.append(piece)
                }
                position += piece.reading.count
            }
            return merged
        }
    }

    /// 表記を選んだ文節 chosen の範囲で reading を前・その文節・後ろに分け、前と後ろはそれぞれ left に続けて変換して文節に分ける。
    /// 前と後ろにある、守る文節も守る（`keepingFixedRanges`）
    private func splitting(
        _ reading: String, around chosen: KeptClause, keeping fixed: [KeptClause], context: JapaneseContext, span: ClauseSpan, left: String
    ) -> [Clause] {
        var made: [Clause] = []
        var text = left
        let head = String(reading.prefix(chosen.range.lowerBound))
        if !head.isEmpty {
            made += keepingFixedRanges(
                fixed.filter { $0.range.upperBound <= chosen.range.lowerBound },
                in: japaneseConverter.display(kana: head, context: context, left: text),
                reading: head, context: context, span: span, left: text
            )
            text += made.map(\.output).joined()
        }
        let middle = String(reading.dropFirst(chosen.range.lowerBound).prefix(chosen.range.count))
        let middleContext = head.isEmpty ? context : .afterWord
        var clause = Clause(
            kind: .japanese,
            reading: middle,
            candidates: japaneseCandidates(
                reading: middle, best: japaneseConverter.display(kana: middle, context: middleContext, left: text).text, context: middleContext, span: span
            ),
            selected: 0,
            span: span
        )
        chosen.apply(to: &clause)
        made.append(clause)
        text += clause.output
        let tail = String(reading.dropFirst(chosen.range.upperBound))
        if !tail.isEmpty {
            made += keepingFixedRanges(
                fixed.filter { $0.range.lowerBound >= chosen.range.upperBound }.map { $0.shifted(by: -chosen.range.upperBound) },
                in: japaneseConverter.display(kana: tail, context: .afterWord, left: text),
                reading: tail, context: .afterWord, span: span, left: text
            )
        }
        return made
    }

    /// index の文節までを確定するときの、確定する文字列、残りの文節、残りの打鍵列。
    /// 直後に続く空白だけの文節も一緒に確定するので、残りは空白だけの文節で始まらない（空白だけが残るなら残りは空）。
    /// 日本語区間の途中で切るときは、残りをその位置から始まる区間として持ち直す。切る位置に当たる打鍵が決まらなければ nil
    public func commit(_ clauses: [Clause], through index: Int) -> (text: String, rest: [Clause], keys: String)? {
        var index = index
        while index + 1 < clauses.count, clauses[index + 1].isSpace { index += 1 }
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
        // 読みが記号の読みなら、その記号も選べる（かっこ の 【】）
        list += SymbolCandidates.symbols(for: reading)
        if whole, !typedCanBeEnglish { list.append(span.source) }
        return Self.unique(list)
    }

    private func candidates(for segment: Segment) -> [String] {
        var list: [String] = [segment.output]
        switch segment.kind {
        case .punctuation:
            // 記号の打鍵のうち 2 打鍵のもの（z[ zl）は、打ったままの形を候補にしない（打ったままにするのは F10）。
            // 1 打鍵のもの（[ ] /）と句読点は、打ったままの形を選べる。句読点は日本語の記号も選べる。
            // 組の開き括弧に合わせて打ったままの形にした閉じ括弧もある
            if Self.symbols[segment.source] == nil || segment.source.count == 1 { list.append(segment.source) }
            if let mark = segment.source.first.flatMap({ Self.punctuation[$0] }) { list.append(mark) }
            // 表示の記号を読みとする記号も選べる（「 の 【）。丸括弧は候補を選ぶと組の括弧も同じ形にする（pairingBrackets）ので、
            // 丸括弧の文節にほかの記号を足すと組が合わなくなる。丸括弧の文節には足さない
            if !Self.isRoundBracket(segment.output) { list += SymbolCandidates.symbols(for: segment.output) }
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
