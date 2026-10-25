import Foundation

enum Kana {
    /// ひらがな（ぁ〜ゖ）を同じ位置のカタカナにする。azooKey が打った読みを辞書で引くときの toKatakana と同じ規則で、
    /// Foundation の hiraganaToKatakana と違い、ゕ ゖ も ヵ ヶ にする
    static func katakana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            (0x3041...0x3096).contains($0.value) ? Unicode.Scalar($0.value + 0x60)! : $0
        }))
    }
}
