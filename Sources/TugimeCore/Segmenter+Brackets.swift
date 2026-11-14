import Foundation

/// 句読点の形と、丸括弧の組
extension Segmenter {
    /// 開き丸括弧ごとの、同じ形の閉じ丸括弧
    static let closingBracket: [Character: Character] = ["(": ")", "（": "）"]

    /// text が丸括弧 1 文字か
    static func isRoundBracket(_ text: String) -> Bool {
        guard text.count == 1, let c = text.first else { return false }
        return closingBracket[c] != nil || closingBracket.values.contains(c)
    }

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
    /// それも丸括弧 1 文字なら同じ形の候補を選ぶ。組の括弧がほかの文字と同じ文節にあるときは変えない。
    /// 先頭以外の候補を選んだ文節は、その表記を選んだ表記（fixedValue）として持つ。先頭の候補に戻すと外す
    public static func selecting(_ index: Int, at focus: Int, in clauses: [Clause]) -> [Clause] {
        guard clauses.indices.contains(focus), clauses[focus].candidates.indices.contains(index) else {
            return Unexpected.reached("選ぶ候補が候補の範囲の外（文節、候補、文節の数）", numbers: [focus, index, clauses.count], continuingWith: clauses)
        }
        var selected = clauses
        selected[focus].select(index)
        return punctuatingAfter(pairingBrackets(selected, at: focus), at: focus)
    }

    /// 文節 focus の後ろの句読点の文節（空白だけの文節は飛ばす）を、focus までに見えている表記の最後の字で決め直す（AI を 愛 に選び替えたら , を 、 に）。
    /// 句読点の形を選んだ文節（fixedValue）と、組の開き丸括弧で形が決まる閉じ丸括弧は替えない。開き丸括弧を替えたら組の閉じ丸括弧も合わせる
    private static func punctuatingAfter(_ clauses: [Clause], at focus: Int) -> [Clause] {
        let next = clauses.indices.dropFirst(focus + 1).first { !clauses[$0].output.allSatisfy { $0 == " " } } ?? clauses.endIndex
        guard clauses[focus].kind != .punctuation, clauses.indices.contains(next), clauses[next].kind == .punctuation, clauses[next].fixedValue == nil,
              let typed = clauses[next].candidates.first(where: { $0.count == 1 && Segmenter.punctuation[$0.first!] != nil }),
              typed != ")", let japanese = Segmenter.punctuation[typed.first!], clauses[next].candidates.contains(japanese)
        else { return clauses }
        let wanted = Segmenter.keepsPunctuationTyped(afterText: clauses[..<next].map(\.output).joined()) ? typed : japanese
        guard let index = clauses[next].candidates.firstIndex(of: wanted), index != clauses[next].selected else { return clauses }
        var redecided = clauses
        redecided[next].selected = index
        return pairingBrackets(redecided, at: next)
    }

    /// 文節 focus で表記 text を選ぶ。候補に無ければ末尾に足して選ぶ（F6〜F10 で作った文字種）。組になる括弧も selecting と同じく合わせる
    public static func selecting(text: String, at focus: Int, in clauses: [Clause]) -> [Clause] {
        guard clauses.indices.contains(focus) else {
            return Unexpected.reached("表記を選ぶ文節が文節の範囲の外（文節、文節の数）", numbers: [focus, clauses.count], continuingWith: clauses)
        }
        var added = clauses
        let index = added[focus].candidateIndex(adding: text)
        return selecting(index, at: focus, in: added)
    }

    private mutating func select(_ index: Int) {
        selected = index
        fixedValue = index == 0 ? nil : candidates[index]
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
        paired[target].select(index)
        return paired
    }
}
