import Foundation

/// 未確定の文字列全体か、選んでいる文節を 1 つの文字種にする変換（標準の日本語入力の F6〜F10）
public enum WholeConversion: Sendable, CaseIterable {
    case hiragana
    case katakana
    case halfwidthKatakana
    case fullwidthRoman
    case roman
}

extension Segmenter {
    /// 日本語区間はかな、英語区間は綴りの表で読めればかな、読めなければ打ったまま、を並べたもの
    public func wholeReading(_ input: String, leading: Leading = .start) -> String {
        segment(input, leading: leading).map { segment in
            switch segment.kind {
            case .japanese, .punctuation: segment.reading
            case .english: table.reading(of: segment.source) ?? segment.source
            }
        }.joined()
    }

    public func convertWhole(_ input: String, to kind: WholeConversion, leading: Leading = .start) -> String {
        Self.form(kana: wholeReading(input, leading: leading), typed: input, kind)
    }

    /// index の文節だけを指定の文字種にした文字列。日本語の文節を英字にするときは、区間の打鍵からその文節に当たる部分を切り出す
    public func convertClause(_ clauses: [Clause], at index: Int, to kind: WholeConversion) -> String {
        let clause = clauses[index]
        let typed = typedSource(of: clauses, at: index)
        let kana = switch clause.kind {
        case .japanese, .punctuation: clause.reading
        case .english: table.reading(of: typed) ?? typed
        }
        return Self.form(kana: kana, typed: typed, kind)
    }

    /// index の文節に当たる打鍵。英語と句読点の文節は区間と同じ。日本語の文節は、区間の打鍵を同じ区間の前の文節の読みの長さで切る
    private func typedSource(of clauses: [Clause], at index: Int) -> String {
        let clause = clauses[index]
        let span = clause.span
        guard clause.kind == .japanese else { return span.source }
        let start = clauses[..<index].filter { $0.span == span }.map(\.reading.count).reduce(0, +)
        let afterStart = start == 0 ? span.source : table.split(span.source, kana: span.reading, atKana: start)?.tail
        guard let afterStart else { preconditionFailure("区間の打鍵を文節の始まりで切れない: \(span.source) \(start)") }
        let restReading = String(span.reading.dropFirst(start))
        guard clause.reading.count < restReading.count else { return afterStart }
        guard let head = table.split(afterStart, kana: restReading, atKana: clause.reading.count)?.head else {
            preconditionFailure("区間の打鍵を文節の終わりで切れない: \(afterStart) \(clause.reading.count)")
        }
        return head
    }

    private static func form(kana: String, typed: String, _ kind: WholeConversion) -> String {
        switch kind {
        case .hiragana:
            kana
        case .katakana:
            kana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? kana
        case .halfwidthKatakana:
            form(kana: kana, typed: typed, .katakana).applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? kana
        case .fullwidthRoman:
            typed.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? typed
        case .roman:
            typed
        }
    }

    /// 未確定の文字列を確定・取り消ししたときに呼ぶ
    public func endComposition() {
        japaneseConverter.endComposition()
    }
}
