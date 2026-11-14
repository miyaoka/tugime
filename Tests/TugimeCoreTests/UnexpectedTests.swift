import Testing
@testable import TugimeCore

/// 想定外の状態に当たった操作は、止まらずに結果を捨てる。入力メソッドはそれを受けて、打鍵と表示を操作の前のまま残す
@Suite struct UnexpectedTests {
    /// 内側の範囲で当たったことは、外側の操作の結果も捨てさせる。内側が当たったことを知って結果を覚えずにいても、外側の操作は壊れた値で進んでいる
    @Test func discardsTheOuterOperationWhenAnInnerRangeReached() {
        Unexpected.$stopsInDebug.withValue(false) {
            let outer = Unexpected.guarded { Unexpected.watching { Unexpected.reached("内側", continuingWith: 1) }.value }
            let inner = Unexpected.watching { Unexpected.reached("内側", continuingWith: 1) }
            #expect(outer == nil)
            #expect(inner.reached)
        }
    }

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
            Unexpected.reached("操作の外", continuingWith: ())
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
