import Foundation

/// 句読点の形と、丸括弧の組
extension Segmenter {
    /// 開き丸括弧ごとの、同じ形の閉じ丸括弧
    static let closingBracket: [Character: Character] = ["(": ")", "（": "）"]

    /// 句読点 c の区間の形。直前の区間が英語なら nil（打ったまま英語の区間に含める）、日本語なら日本語の記号にする。
    /// 閉じ丸括弧は、opened の最後の開き丸括弧（入れ子を数えて組になるもの）と同じ形にし、opened から外す。全角なら直前が英語でも区間にし、
    /// 半角なら直前が日本語でも半角の区間にする。組が無ければほかの句読点と同じ。
    /// 開き丸括弧は、決めた形を opened に積む
    static func punctuationMark(_ c: Character, opened: inout [Character], previousIsEnglish: Bool) -> String? {
        if closingBracket.values.contains(c), let opener = opened.popLast() {
            if opener == "(" { return previousIsEnglish ? nil : ")" }
            return "）"
        }
        if closingBracket[c] != nil { opened.append(previousIsEnglish ? c : "（") }
        return previousIsEnglish ? nil : punctuation[c]
    }

    /// text の中で閉じていない開き丸括弧。外側から順に並べる
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
    /// 文節 focus の候補 index を選ぶ。その文節が丸括弧 1 文字なら、入れ子を数えて組になる括弧の文節を探し、
    /// それも丸括弧 1 文字なら同じ形の候補を選ぶ。組の括弧がほかの文字と同じ文節にあるときは変えない
    public static func selecting(_ index: Int, at focus: Int, in clauses: [Clause]) -> [Clause] {
        var selected = clauses
        selected[focus].selected = index
        return pairingBrackets(selected, at: focus)
    }

    private static func pairingBrackets(_ clauses: [Clause], at focus: Int) -> [Clause] {
        guard clauses[focus].output.count == 1, let c = clauses[focus].output.first else { return clauses }
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
