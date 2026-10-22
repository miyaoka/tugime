import Foundation

/// 未確定の文字列全体を 1 つの文字種にする変換（標準の日本語入力の F6〜F10）
public enum WholeConversion: Sendable, CaseIterable {
    case hiragana
    case katakana
    case halfwidthKatakana
    case fullwidthRoman
    case roman
}

extension Segmenter {
    /// 日本語区間はかな、英語区間は綴りの表で読めればかな、読めなければ打ったまま、を並べたもの
    public func wholeReading(_ input: String) -> String {
        segment(input).map { segment in
            switch segment.kind {
            case .japanese, .punctuation: segment.reading
            case .english: table.reading(of: segment.source) ?? segment.source
            }
        }.joined()
    }

    public func convertWhole(_ input: String, to kind: WholeConversion) -> String {
        switch kind {
        case .hiragana:
            wholeReading(input)
        case .katakana:
            wholeReading(input).applyingTransform(.hiraganaToKatakana, reverse: false) ?? input
        case .halfwidthKatakana:
            convertWhole(input, to: .katakana).applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? input
        case .fullwidthRoman:
            input.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? input
        case .roman:
            input
        }
    }
}
