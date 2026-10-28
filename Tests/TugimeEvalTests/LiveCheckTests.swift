import Testing
import TugimeCore
@testable import TugimeEval

@Suite struct LiveCheckTests {
    let table = try! RomajiTable.bundled()

    func judge(_ display: String, _ typed: String, _ answer: String, _ reading: String) -> LiveCheck {
        LiveCheck.judge(display: display, typed: typed, answers: [answer], reading: reading, table: table)
    }

    /// 末尾の読み切れない打鍵だけを打ちかけとして除く。促音の t は次の綴りが来るまで読めないので打ちかけ
    @Test func dropsOnlyTheUnreadKeys() {
        #expect(judge("明日は会議がありm", "asitahakaigigaarim", "明日は会議があります", "あしたはかいぎがあります") == .followsAnswer)
        #expect(judge("行っt", "itt", "行ったのですか", "いったのですか") == .followsAnswer)
        #expect(judge("明日は会議がarim", "asitahakaigigaarim", "明日は会議があります", "あしたはかいぎがあります") == .leftLetters)
    }

    /// 打っている語をかなのまま見せるのは正解に向かっている。かなが読みと違えば外れる
    @Test func acceptsTheReadingShownAsKana() {
        #expect(judge("の依頼がくr", "noiraigakur", "の依頼が来る", "のいらいがくる") == .followsAnswer)
        #expect(judge("の依頼がク", "noiraigaku", "の依頼が来る", "のいらいがくる") == .followsAnswer)
        #expect(judge("の依頼がけ", "noiraigake", "の依頼が来る", "のいらいがくる") == .offAnswer)
    }

    @Test func tellsAWordTheAnswerDoesNotStartWith() {
        #expect(judge("それは賞玩", "sorehasyougan", "それはしょうがないと思います", "それはしょうがないとおもいます") == .offAnswer)
        #expect(judge("私は寿司ヲタbet", "watasihasusiwotabet", "私は寿司を食べたい", "わたしはすしをたべたい") == .leftLetters)
        #expect(judge("私は寿司を食べt", "watasihasusiwotabet", "私は寿司を食べたい", "わたしはすしをたべたい") == .followsAnswer)
    }

    /// 英字を含む正解では、途中の英字を数えず先頭の一致だけを見る
    @Test func countsLettersOnlyWhenTheAnswerHasNone() {
        #expect(judge("pullreq", "pullreq", "pullrequestを作って", "pullrequestをつくって") == .followsAnswer)
        #expect(judge("pullレク", "pullreku", "pullrequestを作って", "pullrequestをつくって") == .offAnswer)
    }
}
