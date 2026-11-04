import Testing
@testable import TugimeCore

@Suite struct CandidatePageTests {
    /// どの候補を選んでいても、選んでいる候補は見えている範囲にあり、番号は見えている行に 1 から振られ、
    /// その番号で選ぶ候補は、その番号を描いた行の候補になる。見えている行に無い番号は選ばない
    @Test(arguments: [(count: 5, moves: [0, 4, 2]), (count: 12, moves: [0, 9, 11, 0, 11, 2])])
    func selectsTheCandidateDrawnWithTheNumber(count: Int, moves: [Int]) {
        var page = CandidatePage(count: count, selected: moves[0])
        for index in moves {
            page.select(index)
            #expect(page.visible.contains(page.selected))
            #expect(page.visible.count == min(count, CandidatePage.rows))
            #expect(page.numbered.map(\.number) == Array(1...page.visible.count))
            for (number, drawn) in page.numbered {
                #expect(page.index(forNumber: number) == drawn)
            }
            #expect(page.index(forNumber: 0) == nil)
            #expect(page.index(forNumber: page.visible.count + 1) == nil)
        }
    }

    /// 窓を開いたときに選んでいる候補が最初の画面より後ろでも、その候補が見えている
    @Test func showsTheSelectedCandidateWhenOpened() {
        let page = CandidatePage(count: 15, selected: 12)
        #expect(page.visible.contains(12))
    }
}
