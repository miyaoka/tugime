import Testing
@testable import TugimeCore

@Suite struct CandidatePageTests {
    /// スクロールしていなければ、番号はそのまま候補の位置になる。見えている行より大きい番号は選ばない
    @Test func numbersTheVisibleRowsFromTheTop() {
        let page = CandidatePage(count: 5, selected: 0)
        #expect(page.visible == 0..<5)
        #expect(page.index(forNumber: 1) == 0)
        #expect(page.index(forNumber: 5) == 4)
        #expect(page.index(forNumber: 6) == nil)
        #expect(page.index(forNumber: 0) == nil)
    }

    /// 見えている範囲の下へ選ぶ候補を進めると、その候補が最後の行に来るまで範囲を送り、番号も送った範囲に振る
    @Test func scrollsSoTheSelectedCandidateStaysVisible() {
        var page = CandidatePage(count: 12, selected: 0)
        #expect(page.visible == 0..<9)
        page.select(9)
        #expect(page.visible == 1..<10)
        #expect(page.index(forNumber: 1) == 1)
        #expect(page.index(forNumber: 9) == 9)
        page.select(11)
        #expect(page.visible == 3..<12)
        // 最後から最初へ回ったときは、最初の候補が最初の行に来る
        page.select(0)
        #expect(page.visible == 0..<9)
    }

    /// 見えている範囲の上へ戻ったときは、その候補が最初の行に来るまで戻す
    @Test func scrollsBackWhenSelectingAboveTheVisibleRows() {
        var page = CandidatePage(count: 12, selected: 11)
        #expect(page.visible == 3..<12)
        page.select(2)
        #expect(page.visible == 2..<11)
        #expect(page.index(forNumber: 1) == 2)
    }
}
