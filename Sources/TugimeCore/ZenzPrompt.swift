import Foundation

/// zenz 形式のモデル（genmai など）に渡す入力の文字列と、出力の扱い。トークンにはしない（語彙はモデルが持つ）。
/// 規則は genmai の作者の実装（genmai-ime の GenmaiPrompt と GenmaiModel）に合わせる:
/// - "\u{EE02}" + 左の文脈 + "\u{EE00}" + カタカナにした読み + "\u{EE01}"。左の文脈が空なら "\u{EE00}" から始める。先頭の BOS はモデルの側で足す
/// - 左の文脈は最後の 500 字。空白は全角の空白にし、改行は除く
/// - 40 字を超える読みは句読点で区切り、前の区切りの出力を左の文脈に足して続きを変換する
/// - 出力は読みの 1.3 倍 + 8 トークンまで生成し、最初の改行で切る
enum ZenzPrompt {
    static let contextMark = "\u{EE02}"
    static let inputMark = "\u{EE00}"
    static let outputMark = "\u{EE01}"
    static let maxContextLength = 500
    static let chunkLength = 40
    static let outputPerKana = 1.3
    static let outputMargin = 8
    private static let chunkEnds: Set<Unicode.Scalar> = ["、", "。", "，", "．", "！", "？", "!", "?"]

    /// 左の文脈。left が空でなければ left。left が空で数字に続くなら、その数字（入力欄に確定済みの数字で、未確定の文字列の中に無いとき）。
    /// それ以外は空。afterWord で left が空なのは、前の語が未確定の文字列の外にあるとき（入力欄に確定済みの英語、またはカーソルの前の文字）で、
    /// その語を tugime は知らないので、仮の語を置かずに文脈なしで変換する
    static func leftContext(context: JapaneseContext, left: String) -> String {
        guard left.isEmpty else { return left }
        switch context {
        case .afterNumber(let digits): return digits
        case .start, .afterWord: return ""
        case .afterCaret: preconditionFailure("afterCaret は convert で文頭か前の語に続く形に決めてから渡す")
        }
    }

    static func text(left: String, kana: String) -> String {
        let context = String(String.UnicodeScalarView(left.unicodeScalars.suffix(maxContextLength)))
        return preprocess((context.isEmpty ? "" : contextMark + context) + inputMark + katakana(kana) + outputMark)
    }

    /// モデルの出力の全角の空白を、入力の空白に戻す
    static func restoreSpaces(_ output: String) -> String {
        output.replacingOccurrences(of: "\u{3000}", with: " ")
    }

    /// 1 つの区切りの出力。最初の改行より後は捨てる
    static func cutAtNewline(_ output: String) -> String {
        output.firstIndex(of: "\n").map { String(output[..<$0]) } ?? output
    }

    /// 1 つの区切りで生成するトークン数の上限。上限で止まった出力も、そのまま出力にする
    static func outputLimit(_ kana: String) -> Int {
        Int(Double(kana.unicodeScalars.count) * outputPerKana) + outputMargin
    }

    /// 句読点で終わる部分を、chunkLength 字を超えない範囲で前から順にまとめる。読みが伸びるだけなら、最後以外の区切りは変わらない
    static func chunks(_ kana: String) -> [String] {
        let scalars = Array(kana.unicodeScalars)
        guard scalars.count > chunkLength else { return [kana] }
        var raw: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for s in scalars {
            current.append(s)
            if chunkEnds.contains(s) {
                raw.append(current)
                current = []
            }
        }
        if !current.isEmpty { raw.append(current) }
        var parts: [[Unicode.Scalar]] = []
        for p in raw {
            if let last = parts.last, last.count + p.count <= chunkLength {
                parts[parts.count - 1] += p
            } else {
                parts.append(p)
            }
        }
        return parts.map { String(String.UnicodeScalarView($0)) }
    }

    private static func katakana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            (0x3041...0x3096).contains($0.value) ? Unicode.Scalar($0.value + 0x60)! : $0
        }))
    }

    private static func preprocess(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.compactMap { $0 == "\n" ? nil : $0 == " " ? "\u{3000}" : $0 }))
    }
}
