import Testing
@testable import TugimeCore

/// 想定外の状態に当たった操作は、止まらずに結果を捨てる。入力メソッドはそれを受けて、打鍵と表示を操作の前のまま残す。
/// 結果は #expect の外で受けてから確かめる（#expect の式の中に閉包を書くと、直前の文との並びで結果が食い違うことがある）
@Suite struct UnexpectedTests {
    @Test func discardsTheResultOfAnOperationThatReachedAnUnexpectedState() {
        Unexpected.$stopsInDebug.withValue(false) {
            let reached = Unexpected.guarded { Unexpected.reached("想定外", continuingWith: 1) }
            let plain = Unexpected.guarded { 1 }
            #expect(reached == nil)
            #expect(plain == 1)
        }
    }

    /// 操作の外や前の操作で当たった状態は、後の操作の結果を捨てさせない
    @Test func keepsTheNextOperationApartFromAnEarlierOne() {
        Unexpected.$stopsInDebug.withValue(false) {
            _ = Unexpected.reached("操作の外", continuingWith: ())
            let earlier = Unexpected.guarded { Unexpected.reached("前の操作", continuingWith: 0) }
            let next = Unexpected.guarded { 2 }
            #expect(earlier == nil)
            #expect(next == 2)
        }
    }

    /// 候補の範囲の外を選ぶ操作は、止まらずに結果を捨てる
    @Test func discardsSelectingACandidateOutsideTheCandidates() {
        Unexpected.$stopsInDebug.withValue(false) {
            let outside = Unexpected.guarded { CandidatePage(count: 2, selected: 5) }
            let inside = Unexpected.guarded { CandidatePage(count: 2, selected: 1) }
            #expect(outside == nil)
            #expect(inside != nil)
        }
    }
}
