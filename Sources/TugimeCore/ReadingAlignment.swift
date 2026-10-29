import Foundation

/// 変換の出力の文字列を、その読みのかなに対応づけたもの。辞書もモデルも使わない。
/// 表示の文節の切り方（DirectConverter）と、読みとの対応を確かめられなかった出力の数え方（tugime-eval の集計）が、同じこれを使う。
///
/// 対応の取り方:
/// - 出力のかな（ひらがな・カタカナ・ー）は錨。カタカナはひらがなに直し、読みの次の 1 文字と一致しなければならない
/// - それ以外の文字（漢字・数字・英字・記号）の連なりは、読みを 1 文字以上、何文字でも食う
/// - 出力の全体が読みの全体をちょうど食い尽くす食い方が 1 つ以上あれば対応づく。無ければ init は nil
///
/// 漢字の連なりは読みを何文字でも食うので、連なりの中の脱落や追加は対応づいてしまう。対応づかない出力の数は、読みと違う出力の下限である
public struct ReadingAlignment: Sendable, Equatable {
    public let text: String
    public let reading: String
    /// 出力の位置ごとに、すべての食い方で同じ読みの位置に当たるならその位置。連なりの内側か、食い方で位置が変わるなら nil。
    /// 確定した位置は出力の位置について真に増え、出力の始まりは読みの始まりに、出力の終わりは読みの終わりに必ず確定する
    let fixed: [Int?]

    private enum Piece {
        case anchor(Character)
        case run
    }

    public init?(text: String, reading: String) {
        let t = Array(text)
        let r = Array(reading)
        let n = r.count
        // 出力を錨と連なりに分け、それぞれの始まりの出力の位置を持つ
        var pieces: [(piece: Piece, start: Int)] = []
        for (j, c) in t.enumerated() {
            if let h = Self.anchor(c) {
                pieces.append((.anchor(h), j))
            } else if case .run = pieces.last?.piece {
                continue
            } else {
                pieces.append((.run, j))
            }
        }
        // forward[i][p]: 先頭の i 個の部分で、読みの先頭 p 文字を食い得る
        var forward = [[Bool]](repeating: [Bool](repeating: false, count: n + 1), count: pieces.count + 1)
        forward[0][0] = true
        for (i, entry) in pieces.enumerated() {
            switch entry.piece {
            case .anchor(let h):
                for p in 0..<n where forward[i][p] && r[p] == h { forward[i + 1][p + 1] = true }
            case .run:
                var reachable = false
                for q in 0...n {
                    if reachable { forward[i + 1][q] = true }
                    if forward[i][q] { reachable = true }
                }
            }
        }
        guard forward[pieces.count][n] else { return nil }
        // alive[i][p]: forward[i][p] で、かつ残りの部分で読みの終わりまで食い切れる
        var alive = [[Bool]](repeating: [Bool](repeating: false, count: n + 1), count: pieces.count + 1)
        alive[pieces.count][n] = true
        for i in stride(from: pieces.count - 1, through: 0, by: -1) {
            switch pieces[i].piece {
            case .anchor(let h):
                for p in 0..<n where forward[i][p] && r[p] == h && alive[i + 1][p + 1] { alive[i][p] = true }
            case .run:
                var later = false
                for p in stride(from: n, through: 0, by: -1) {
                    if forward[i][p] && later { alive[i][p] = true }
                    if alive[i + 1][p] { later = true }
                }
            }
        }
        var fixed = [Int?](repeating: nil, count: t.count + 1)
        for (i, boundary) in (pieces.map(\.start) + [t.count]).enumerated() {
            let positions = alive[i].indices.filter { alive[i][$0] }
            fixed[boundary] = positions.count == 1 ? positions[0] : nil
        }
        self.text = text
        self.reading = reading
        self.fixed = fixed
    }

    /// 出力の位置 index に当たる読みの位置。どの食い方でも同じ位置に当たるときだけ返す
    public func readingPosition(atText index: Int) -> Int? {
        fixed[index]
    }

    /// 読みの位置 cuts（0 と読みの終わりを含まない昇順）で出力を文節に切る。出力の側で確定した位置に当たらない cut は捨て、
    /// その両側を 1 つの文節にする。返す文節は 1 つ以上で、どれも読みと表記が空でなく、読みを繋ぐと reading、表記を繋ぐと text になる
    public func clauses(cutAt cuts: [Int]) -> [JapaneseClause] {
        let t = Array(text)
        let r = Array(reading)
        let inner = cuts.compactMap { c in fixed.firstIndex(of: c).map { (reading: c, text: $0) } }
        let points = [(reading: 0, text: 0)] + inner + [(reading: r.count, text: t.count)]
        return zip(points, points.dropFirst()).map { a, b in
            JapaneseClause(reading: String(r[a.reading..<b.reading]), text: String(t[a.text..<b.text]))
        }
    }

    /// 錨として扱う文字なら、比べるためのひらがな。小さい か・け（ゕ ゖ ヵ ヶ）は「か」「が」「こ」と読まれるので錨にしない
    public static func anchor(_ c: Character) -> Character? {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return nil }
        switch s.value {
        case 0x3041...0x3094, 0x30FC:
            return c
        case 0x30A1...0x30F4:
            return Character(Unicode.Scalar(s.value - 0x60)!)
        default:
            return nil
        }
    }
}
