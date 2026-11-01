import Foundation

/// 丸括弧の組の形をそろえる
extension Segmenter {
    /// 開き括弧ごとの、同じ形の閉じ括弧
    static let closingBracket: [Character: Character] = ["(": ")", "（": "）"]

    /// 区間の表記の中の閉じ括弧を、組になる開き括弧と同じ形にする。開き括弧の形は句読点として直前の区間で決まっている。
    /// 組は入れ子を数えて決める。未確定の文字列の中に組になる開き括弧が無ければ、入力欄のカーソルより前の文字列 before の
    /// 閉じていない開き括弧と内側から組にする。どちらにも無ければ、閉じ括弧は直前の区間で決まった形のまま
    static func aligningBrackets(_ segments: [Segment], before: String) -> [Segment] {
        var aligned = segments
        var opened = unclosedOpeners(in: before)
        for index in aligned.indices where aligned[index].kind == .english || aligned[index].kind == .punctuation {
            var output = Array(aligned[index].output)
            for offset in output.indices {
                let c = output[offset]
                if closingBracket[c] != nil {
                    opened.append(c)
                    continue
                }
                guard closingBracket.values.contains(c), let opener = opened.popLast(), let closer = closingBracket[opener] else { continue }
                output[offset] = closer
            }
            aligned[index].output = String(output)
            if aligned[index].kind == .punctuation { aligned[index].reading = aligned[index].output }
        }
        return aligned
    }

    /// text の中で閉じていない開き括弧。外側から順に並べる
    static func unclosedOpeners(in text: String) -> [Character] {
        var opened: [Character] = []
        for c in text {
            if closingBracket[c] != nil {
                opened.append(c)
            } else if closingBracket.values.contains(c), !opened.isEmpty {
                opened.removeLast()
            }
        }
        return opened
    }
}

extension Clause {
    /// 文節 focus の候補を選び直した後に呼ぶ。その文節が括弧 1 文字なら、入れ子を数えて組になる括弧の文節を探し、
    /// それも括弧 1 文字なら同じ形の候補を選ぶ。組の括弧がほかの文字と同じ文節にあるときは変えない
    public static func pairingBrackets(_ clauses: [Clause], at focus: Int) -> [Clause] {
        guard clauses.indices.contains(focus), clauses[focus].output.count == 1, let c = clauses[focus].output.first else { return clauses }
        let opens = Segmenter.closingBracket
        // 括弧ごとの文節の位置と、開きか
        let brackets: [(clause: Int, open: Bool)] = clauses.indices.flatMap { index in
            clauses[index].output.compactMap { ch in
                opens[ch] != nil ? (index, true) : opens.values.contains(ch) ? (index, false) : nil
            }
        }
        guard let here = brackets.firstIndex(where: { $0.clause == focus }) else { return clauses }
        let open = brackets[here].open
        var depth = 0
        let order = open ? Array(brackets.indices.dropFirst(here + 1)) : Array(brackets.indices.prefix(here).reversed())
        guard let partner = order.first(where: { k in
            if brackets[k].open == open {
                depth += 1
                return false
            }
            if depth == 0 { return true }
            depth -= 1
            return false
        }) else { return clauses }
        let target = brackets[partner].clause
        let wanted = open ? opens[c] : opens.first(where: { $0.value == c })?.key
        guard clauses[target].output.count == 1, let wanted, let index = clauses[target].candidates.firstIndex(of: String(wanted)) else { return clauses }
        var paired = clauses
        paired[target].selected = index
        return paired
    }
}
