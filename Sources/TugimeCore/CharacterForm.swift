import Foundation

/// 1 つの文字種にする変換（標準の日本語入力の F6〜F10）
public enum CharacterForm: Sendable, CaseIterable {
    case hiragana
    case katakana
    case halfwidthKatakana
    case fullwidthRoman
    case roman

    /// 打鍵から作る文字種か。かなの文字種は読みから作る
    var usesKeystrokes: Bool { self == .fullwidthRoman || self == .roman }
}

extension Segmenter {
    /// 日本語区間はかな、英語区間は `englishReading` で読めたもの、読めなければ打ったまま、を並べたもの
    public func wholeReading(_ input: String, leading: Leading = .start) -> String {
        segment(input, leading: leading).map { segment in
            switch segment.kind {
            case .japanese, .punctuation: segment.reading
            case .english, .word: englishReading(of: segment.source) ?? segment.source
            }
        }.joined()
    }

    /// 未確定の文字列全体を指定の文字種にした文字列
    public func convertWhole(_ input: String, to form: CharacterForm, leading: Leading = .start) -> String {
        Self.text(form.usesKeystrokes ? input : wholeReading(input, leading: leading), form)
    }

    /// 未確定の文字列全体を指定の文字種にした 1 文節。読みは `wholeReading`。
    /// 伸縮するときは区切りから文節を作り直す（`resize`）
    public func wholeClause(_ input: String, to form: CharacterForm, leading: Leading = .start) -> Clause {
        let reading = wholeReading(input, leading: leading)
        let span = ClauseSpan(index: 0, source: input, reading: reading, context: leading.japaneseContext)
        return Clause(kind: .whole, reading: reading, candidates: [convertWhole(input, to: form, leading: leading)], selected: 0, span: span)
    }

    /// index の文節だけを指定の文字種にした文字列。英字にするには文節に当たる打鍵が要り、
    /// 文節の境目が 1 つの綴りの途中にあって打鍵を切り出せなければ nil
    public func convertClause(_ clauses: [Clause], at index: Int, to form: CharacterForm) -> String? {
        let clause = clauses[index]
        guard form.usesKeystrokes else {
            let kana = clause.kind == .english || clause.kind == .word ? englishReading(of: clause.span.source) ?? clause.span.source : clause.reading
            return Self.text(kana, form)
        }
        return typedSource(of: clauses, at: index).map { Self.text($0, form) }
    }

    /// source は、打鍵から作る文字種なら打鍵、それ以外ならかな
    private static func text(_ source: String, _ form: CharacterForm) -> String {
        switch form {
        case .hiragana, .roman:
            source
        case .katakana:
            transform(source, .hiraganaToKatakana, reverse: false)
        case .halfwidthKatakana:
            transform(transform(source, .hiraganaToKatakana, reverse: false), .fullwidthToHalfwidth, reverse: false)
        case .fullwidthRoman:
            transform(source, .fullwidthToHalfwidth, reverse: true)
        }
    }

    /// 文字種の変換は名前が決まっているので失敗しない
    private static func transform(_ text: String, _ transform: StringTransform, reverse: Bool) -> String {
        guard let result = text.applyingTransform(transform, reverse: reverse) else {
            preconditionFailure("文字種の変換に失敗した: \(transform.rawValue) \(text)")
        }
        return result
    }

    /// 未確定の文字列を確定・取り消ししたときに呼ぶ
    public func endComposition() {
        japaneseConverter.endComposition()
    }

    /// 利用者の語を置き換える。未確定の文字列は終わる。
    /// 日本語の語は、打鍵をかなに読めればその読みでかな漢字変換に入れ、読めなければ打鍵とちょうど一致する区間をその語にする。
    /// 英語の語は、打鍵とちょうど一致する英語の区間の表記にする
    public func replaceUserDictionary(_ dictionary: UserDictionary) {
        var converted: [UserWord] = []
        var typed: [String: [String]] = [:]
        for (keys, words) in dictionary.words(of: .japanese) {
            guard let kana = table.reading(of: keys), Self.canBeJapanese(kana) else {
                typed[keys] = words
                continue
            }
            converted += words.map { UserWord(reading: kana, word: $0) }
        }
        japaneseConverter.replaceUserWords(converted)
        typedWords = dictionary.words(of: .english)
        typedJapaneseWords = typed
    }
}
