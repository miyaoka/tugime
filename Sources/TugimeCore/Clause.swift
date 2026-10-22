import Foundation

/// 確定前の 1 区間。候補の窓で選び直せる
public struct Clause: Sendable, Equatable {
    public var kind: Segment.Kind
    /// 打鍵列のうちこの区間に当たる部分
    public var source: String
    /// 先頭が区切りを選んだときの結果。重複は無い
    public var candidates: [String]
    public var selected: Int

    public init(kind: Segment.Kind, source: String, candidates: [String], selected: Int) {
        self.kind = kind
        self.source = source
        self.candidates = candidates
        self.selected = selected
    }

    public var output: String { candidates[selected] }
}

extension Segmenter {
    /// 区切りを選び、区間ごとに候補の一覧を付ける
    public func clauses(_ input: String) -> [Clause] {
        let segments = segment(input)
        return segments.enumerated().map { index, segment in
            // 先頭か句読点の直後は文頭として変換する
            let isSentenceStart = index == 0 || segments[index - 1].kind == .punctuation
            return Clause(kind: segment.kind, source: segment.source, candidates: candidates(for: segment, isFirst: isSentenceStart), selected: 0)
        }
    }

    private func candidates(for segment: Segment, isFirst: Bool) -> [String] {
        var list: [String] = [segment.output]
        switch segment.kind {
        case .punctuation:
            list.append(segment.source)
        case .japanese:
            // 日本語区間は日本語区間に続かないので、先頭でなければ直前は英語区間
            let context: JapaneseContext = isFirst ? .start : .afterEnglish
            list += japaneseConverter.alternatives(kana: segment.reading, context: context)
            list += [segment.reading, Self.katakana(segment.reading), segment.source]
        case .english:
            // 英語と判定した区間も、綴りの表で読めればかなを選べるようにする
            if let kana = table.reading(of: segment.source) {
                let context: JapaneseContext = isFirst ? .start : .afterEnglish
                list += [kana, Self.katakana(kana)] + japaneseConverter.alternatives(kana: kana, context: context)
            }
        }
        var seen: Set<String> = []
        return list.filter { seen.insert($0).inserted }
    }

    private static func katakana(_ hiragana: String) -> String {
        hiragana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? hiragana
    }
}
