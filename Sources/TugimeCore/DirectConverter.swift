import Foundation

/// 区間の読みと左の文脈から、表示の文字列を生成するもの。DirectConverter はモデルをこれ越しにだけ使うので、テストではモデルなしに差し替えられる
protocol DirectDisplayGenerating: AnyObject {
    /// left に続く kana の出力。前の生成で覚えたものを使って速くしてよく、そのために出力がそれまでの呼び出しに左右されることがある。
    /// reset の直後の呼び出しは、前の呼び出しに左右されない
    func generate(left: String, kana: String) -> String
    /// 生成を速くするために覚えたものを捨てる。次の未確定の文字列は前の文字列の計算を引き継がない
    func reset()
}

/// 表示の変換だけを zenz 形式のモデルの出力にし、区切りの採点と候補の窓は azooKey（Zenzai なし）に任せる変換器。
///
/// 不変条件:
/// - 表示の text はモデルの出力そのもの。読みと食い違っても azooKey の変換に差し替えない
/// - 表示の clauses は、読みを繋ぐと kana、表記を繋ぐと text。文節の境目の読みの位置は採点の変換から借り、
///   ReadingAlignment で出力の側の位置が確定した境目でだけ切る。対応づかない出力は 1 文節（kana, text）にする
/// - convert が変換を返すかなと文脈には、display も必ず返す
final class DirectConverter: JapaneseConverting {
    private let scorer: any JapaneseConverting
    private let generator: any DirectDisplayGenerating
    /// 区間・文脈・左の文字列ごとの表示。Segmenter は 1 打鍵の中で同じ区間を何度も表示にするので、生成を 1 回にする。未確定の文字列の寿命だけ持つ
    private var displays: [DisplayKey: JapaneseDisplay?] = [:]

    private struct DisplayKey: Hashable {
        var kana: String
        var context: JapaneseContext
        var left: String
    }

    init(scorer: any JapaneseConverting, generator: any DirectDisplayGenerating) {
        self.scorer = scorer
        self.generator = generator
    }

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        scorer.convert(kana: kana, context: context)
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] {
        scorer.alternatives(kana: kana, context: context)
    }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        let key = DisplayKey(kana: kana, context: context, left: left)
        if let cached = displays[key] { return cached }
        let shown = scorer.convert(kana: kana, context: context).map { scored in
            let text = generator.generate(left: ZenzPrompt.leftContext(context: context, left: left), kana: kana)
            var cuts: [Int] = []
            for scoredClause in scored.clauses.dropLast() { cuts.append((cuts.last ?? 0) + scoredClause.clause.reading.count) }
            let clauses = ReadingAlignment(text: text, reading: kana)?.clauses(cutAt: cuts) ?? [JapaneseClause(reading: kana, text: text)]
            return JapaneseDisplay(text: text, clauses: clauses)
        }
        displays[key] = shown
        return shown
    }

    func endComposition() {
        scorer.endComposition()
        generator.reset()
        displays = [:]
    }
}
