import Foundation

/// zenz 形式のモデル（genmai など）に渡す入力の文字列と、出力の扱い。トークンにはしない（語彙はモデルが持つ）。
/// 規則は genmai の作者の実装（genmai-ime の GenmaiPrompt と GenmaiModel）に合わせる:
/// - "\u{EE02}" + 左の文脈 + "\u{EE00}" + カタカナにした読み + "\u{EE01}"。左の文脈が空なら "\u{EE00}" から始める。先頭の BOS はモデルの側で足す
/// - 左の文脈は最後の 500 字。空白は全角の空白にし、改行は除く
/// - 40 字を超える読みは句読点で区切り、前の区切りの出力を左の文脈に足して続きを変換する
/// - 出力は読みの 1.3 倍 + 8 トークンまで生成し、最初の改行で切る
package enum ZenzPrompt {
    static let contextMark = "\u{EE02}"
    static let inputMark = "\u{EE00}"
    static let outputMark = "\u{EE01}"
    package static let maxContextLength = 500
    static let chunkLength = 40
    static let outputPerKana = 1.3
    static let outputMargin = 8
    private static let chunkEnds: Set<Unicode.Scalar> = ["、", "。", "，", "．", "！", "？", "!", "?"]
    /// 出力の文法（llama.cpp の GBNF）。目印を含まない文字の並び
    package static let outputGrammar = "root ::= [^\(inputMark)\(outputMark)\(contextMark)]*"

    /// 左の文脈。left が空でなければ left。left が空で数字に続くなら、その数字。
    /// それ以外は空。afterWord で left が空なのは、前の語がある入力欄のカーソルより前の文字列を読めなかったときで、
    /// その語を tugime は知らないので、仮の語を置かずに文脈なしで変換する
    static func leftContext(context: JapaneseContext, left: String) -> String {
        guard left.isEmpty else { return left }
        switch context {
        case .afterNumber(let digits): return digits
        case .start, .afterWord: return ""
        case .afterCaret: return Unexpected.reached("afterCaret は convert で文頭か前の語に続く形に決めてから渡す", continuingWith: "")
        }
    }

    package static func text(left: String, kana: String) -> String {
        let context = String(String.UnicodeScalarView(left.unicodeScalars.suffix(maxContextLength)))
        return preprocess((context.isEmpty ? "" : contextMark + context) + inputMark + Kana.katakana(kana) + outputMark)
    }

    /// モデルの出力の全角の空白を、入力の空白に戻す
    package static func restoreSpaces(_ output: String) -> String {
        output.replacingOccurrences(of: "\u{3000}", with: " ")
    }

    /// 出力のバイト列から、末尾で字の途中に切れたバイトを除く。出力の上限で止まると、最後のトークンが字の途中で終わることがある。
    /// llama.cpp の server の validate_utf8 と同じく、末尾の 4 バイトまでに字の頭を探し、字に要るバイトが足りなければそこで切る
    package static func droppingIncompleteTail(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        for back in 1...4 where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            // 続きのバイト（10xxxxxx）は字の頭ではないので、さらに前を見る
            if byte & 0xC0 == 0x80 { continue }
            let length = byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : byte & 0xF8 == 0xF0 ? 4 : 1
            return length > back ? bytes.dropLast(back) : bytes[...]
        }
        return bytes[...]
    }

    /// 1 つの区切りの出力。最初の改行より後は捨てる
    package static func cutAtNewline(_ output: String) -> String {
        output.firstIndex(of: "\n").map { String(output[..<$0]) } ?? output
    }

    /// 1 つの区切りで生成するトークン数の上限。上限で止まった出力も、そのまま出力にする
    package static func outputLimit(_ kana: String) -> Int {
        Int(Double(kana.unicodeScalars.count) * outputPerKana) + outputMargin
    }

    /// 出力に位置の半分までを使うとき、1 つの区切りの読みと出力が収まる読みの長さ
    package static func maxChunkLength(positions: Int) -> Int {
        Int(Double(positions / 2 - outputMargin) / outputPerKana)
    }

    /// 句読点で終わる部分を、chunkLength 字を超えない範囲で前から順にまとめる。読みが伸びるだけなら、最後以外の区切りは変わらない。
    /// 句読点の無いまま maxLength 字を超える部分は、maxLength 字ごとに区切る。入力を切り詰めるときに読みが落ちないようにするため
    package static func chunks(_ kana: String, maxLength: Int) -> [String] {
        let scalars = Array(kana.unicodeScalars)
        guard scalars.count > chunkLength else { return [kana] }
        var raw: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for s in scalars {
            current.append(s)
            if chunkEnds.contains(s) || current.count == maxLength {
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

    /// fits が偽を返す区切りを、真を返すまで半分ずつに分ける。読みは削らないので、繋ぐと元の区切りの並びになる。
    /// 1 字でも収まらない区切りは想定外の状態で、分けずに落とす（呼び出し元が同じ区切りを分け直し続けないように）。fits が投げたら、そのまま投げる
    package static func halving<E: Error>(_ parts: [String], until fits: (String) throws(E) -> Bool) throws(E) -> [String] {
        var result: [String] = []
        for part in parts {
            if try fits(part) {
                result.append(part)
                continue
            }
            let scalars = part.unicodeScalars
            guard scalars.count > 1 else {
                Unexpected.reached("1 字の読みが収まらない", detail: part, continuingWith: ())
                continue
            }
            let half = scalars.count / 2
            result += try halving([String(String.UnicodeScalarView(scalars.prefix(half))), String(String.UnicodeScalarView(scalars.dropFirst(half)))], until: fits)
        }
        return result
    }

    private static func preprocess(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.compactMap { $0 == "\n" ? nil : $0 == " " ? "\u{3000}" : $0 }))
    }
}
