/// 候補の窓に見せる範囲と、選んでいる候補。窓は `rows` 行ずつ見せ、見えている行に 1 から番号を振る。
/// 選んでいる候補が見えている範囲の外に出たら、その候補が端の行に来るまで範囲を送る
public struct CandidatePage: Equatable, Sendable {
    public static let rows = 9

    public let count: Int
    public private(set) var selected: Int
    /// 見えている範囲の最初の候補
    public private(set) var first = 0

    public init(count: Int, selected: Int) {
        precondition((0..<count).contains(selected), "選ぶ候補 \(selected) が候補の数 \(count) の外")
        self.count = count
        self.selected = selected
        scrollToSelected()
    }

    public var visible: Range<Int> { first..<min(first + Self.rows, count) }

    public mutating func select(_ index: Int) {
        precondition((0..<count).contains(index), "選ぶ候補 \(index) が候補の数 \(count) の外")
        selected = index
        scrollToSelected()
    }

    /// 見えている行に振った番号（1 始まり）の候補。見えている行に無い番号なら nil
    public func index(forNumber number: Int) -> Int? {
        let index = first + number - 1
        guard number >= 1, visible.contains(index) else { return nil }
        return index
    }

    private mutating func scrollToSelected() {
        if selected < first {
            first = selected
            return
        }
        if selected >= first + Self.rows {
            first = selected - Self.rows + 1
        }
    }
}
