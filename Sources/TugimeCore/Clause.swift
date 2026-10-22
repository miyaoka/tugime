import Foundation

/// 確定前の 1 区間（日本語区間・英語区間・句読点）。候補の窓で選び直せる。日本語区間の中は区切り直さない
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
    public func clauses(_ input: String, leading: Leading = .start) -> [Clause] {
        let segments = segment(input, leading: leading)
        return segments.enumerated().map { index, segment in
            // 句読点の直後は文頭、入力の先頭は入力欄の前の文脈、それ以外は前の語に続く形として変換する
            let context: JapaneseContext = index == 0 ? leading.japaneseContext : segments[index - 1].kind == .punctuation ? .start : .afterWord
            return Clause(kind: segment.kind, source: segment.source, candidates: candidates(for: segment, context: context), selected: 0)
        }
    }

    private func candidates(for segment: Segment, context: JapaneseContext) -> [String] {
        var list: [String] = [segment.output]
        switch segment.kind {
        case .punctuation:
            list.append(segment.source)
        case .japanese:
            list += japaneseConverter.alternatives(kana: segment.reading, context: context)
            list += [segment.reading, Self.katakana(segment.reading), segment.source]
        case .english:
            // 英語と判定した区間も、綴りの表で読めればかなを選べるようにする
            if let kana = table.reading(of: segment.source) {
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
