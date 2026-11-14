import Foundation

/// 区間の読みと左の文脈から、表示の文字列を生成するもの。DirectConverter はモデルをこれ越しにだけ使うので、テストではモデルなしに差し替えられる
package protocol DirectDisplayGenerating: AnyObject {
    /// left に続く kana の出力。前の生成で覚えたものを使って速くしてよく、そのために出力がそれまでの呼び出しに左右されることがある。
    /// reset の直後の呼び出しは、前の呼び出しに左右されない
    func generate(left: String, kana: String) -> String
    /// 生成を速くするために覚えたものを捨てる。次の未確定の文字列は前の文字列の計算を引き継がない
    func reset()
}

/// 表示の変換だけを zenz 形式のモデルの出力にし、区切りの採点と候補の窓はシステム辞書の格子に任せる変換器。
///
/// 不変条件:
/// - 表示の文節は、採点の変換がその文節の読みの中で使った利用者の語を、その語と同じ読みに登録したどれかの表記で含む。
///   モデルは利用者の語を知らないので、これは採点の変換が守る
/// - その上で、表示の文節の表記はモデルの出力を切ったものそのもの。読みと食い違っても採点の変換に差し替えない。
///   前の条件を出力が満たさない文節だけ、その文節の読みに当たる採点の文節の表記を繋いだものにする
/// - 表示の clauses は、読みを繋ぐと kana、表記を繋ぐと text。文節の境目の読みの位置は採点の変換から借り、
///   ReadingAlignment で出力の側の位置が確定した境目でだけ切る。対応づかない出力は 1 文節（kana, 出力）にする。
///   どの境目も採点の文節の境目なので、表示の文節は採点の文節をちょうど何個か束ねたものになる
final class DirectConverter: JapaneseConverting {
    private let scorer: any JapaneseConverting
    private let generator: any DirectDisplayGenerating
    /// 区間・文脈・左の文字列ごとの表示。Segmenter は 1 打鍵の中で同じ区間を何度も表示にするので、生成を 1 回にする。未確定の文字列の寿命だけ持つ
    private var displays: [DisplayKey: JapaneseDisplay] = [:]

    private struct DisplayKey: Hashable {
        var kana: String
        var context: JapaneseContext
        var left: String
    }

    init(scorer: any JapaneseConverting, generator: any DirectDisplayGenerating) {
        self.scorer = scorer
        self.generator = generator
    }

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading {
        scorer.convert(kana: kana, context: context)
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] {
        scorer.alternatives(kana: kana, context: context)
    }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay {
        let key = DisplayKey(kana: kana, context: context, left: left)
        if let cached = displays[key] { return cached }
        let scored = scorer.convert(kana: kana, context: context)
        let text = generator.generate(left: ZenzPrompt.leftContext(context: context, left: left), kana: kana)
        let clauses = Self.keepingUserWords(Self.clauses(of: text, kana: kana, scored: scored.clauses), scored: scored.clauses)
        let shown = JapaneseDisplay(text: clauses.map(\.text).joined(), clauses: clauses, userWords: scored.clauses.flatMap(\.userWords))
        displays[key] = shown
        return shown
    }

    /// 読み kana の表示の文字列 text を、採点の文節 scored の境目のうち、ReadingAlignment で text の側の位置が確定したところで文節に切る。
    /// 対応づかない text は 1 文節（kana, text）にする
    static func clauses(of text: String, kana: String, scored: [ScoredClause]) -> [JapaneseClause] {
        var cuts: [Int] = []
        for scoredClause in scored.dropLast() { cuts.append((cuts.last ?? 0) + scoredClause.clause.reading.count) }
        return ReadingAlignment(text: text, reading: kana)?.clauses(cutAt: cuts) ?? [JapaneseClause(reading: kana, text: text)]
    }

    /// 出力の文節のうち、束ねる採点の文節が使った利用者の語のどれかを、同じ読みに登録したどの表記でも含まないものを、採点の文節の表記を繋いだものにする。
    /// 語の有無は表記に語の文字列が含まれるかで見る。語の読みの位置で差し替えると、出力の漢字の連なりに語の境目が埋もれたときに差し替えられない
    private static func keepingUserWords(_ output: [JapaneseClause], scored: [ScoredClause]) -> [JapaneseClause] {
        var rest = scored[...]
        return output.map { clause in
            var covered: [ScoredClause] = []
            var reading = ""
            while reading.count < clause.reading.count, let next = rest.popFirst() {
                covered.append(next)
                reading += next.clause.reading
            }
            guard reading == clause.reading else {
                return Unexpected.reached("表示の文節が採点の文節の境目で切られていない: \(clause.reading) \(reading)", continuingWith: clause)
            }
            let words = covered.flatMap(\.userWords)
            guard !words.allSatisfy({ word in word.spellings.contains { clause.text.contains($0) } }) else { return clause }
            return JapaneseClause(reading: clause.reading, text: covered.map(\.clause.text).joined())
        }
    }

    func endComposition() {
        scorer.endComposition()
        generator.reset()
        displays = [:]
    }

    /// 生成するものは辞書を知らないが、未確定の文字列が終わるので、覚えた生成も捨てる
    func replaceUserWords(_ words: [UserWord]) {
        scorer.replaceUserWords(words)
        generator.reset()
        displays = [:]
    }
}
