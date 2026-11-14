/// 候補の窓に見せる範囲と、選んでいる候補。窓は `rows` 行ずつ見せ、見えている行に 1 から番号を振る。
/// 選んでいる候補が見えている範囲の外に出たら、その候補が端の行に来るまで範囲を送る
public struct CandidatePage: Equatable, Sendable {
    public static let rows = 9

    public let count: Int
    public private(set) var selected: Int
    /// 見えている範囲の最初の候補
    public private(set) var first = 0

    public init(count: Int, selected: Int) {
        self.count = count
        self.selected = Self.inRange(selected, count: count)
        scrollToSelected()
    }

    /// 候補の範囲に収めた位置。範囲の外は想定外の状態で、操作の結果は `Unexpected.guarded` が捨てる
    private static func inRange(_ index: Int, count: Int) -> Int {
        guard (0..<count).contains(index) else {
            return Unexpected.reached("選ぶ候補が候補の数の外（候補、候補の数）", numbers: [index, count], continuingWith: min(max(index, 0), max(count - 1, 0)))
        }
        return index
    }

    public var visible: Range<Int> { first..<min(first + Self.rows, count) }

    /// 見えている行の番号（1 始まり）と、その行の候補の位置。窓はこの番号を描き、数字キーはこの番号で候補を選ぶ
    public var numbered: [(number: Int, index: Int)] {
        visible.enumerated().map { (number: $0.offset + 1, index: $0.element) }
    }

    public mutating func select(_ index: Int) {
        selected = Self.inRange(index, count: count)
        scrollToSelected()
    }

    /// 見えている行に振った番号（1 始まり）の候補。見えている行に無い番号なら nil
    public func index(forNumber number: Int) -> Int? {
        numbered.first { $0.number == number }?.index
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
