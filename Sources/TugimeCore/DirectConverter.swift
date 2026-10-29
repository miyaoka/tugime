import Foundation

/// 区間の読みと左の文脈から、表示の文字列を生成するもの。DirectConverter はモデルをこれ越しにだけ使うので、テストではモデルなしに差し替えられる
protocol DirectDisplayGenerating: AnyObject {
    /// requests のそれぞれの、left に続く kana の出力。requests と同じ順に返す。まとめて渡したものは同時に生成してよい。
    /// 前の生成で覚えたものを使って速くしてよく、そのために出力がそれまでの呼び出しに左右されることがある。
    /// reset の直後の呼び出しは、前の呼び出しに左右されない
    func generate(_ requests: [GenerationRequest]) -> [String]
    /// left の後に texts のそれぞれを置いたときの、文ごとのトークン列の対数確率の和。texts と同じ順に返す
    /// モデルの位置の上限に収まらない文があって測れなければ nil
    func naturalness(left: String, texts: [String]) -> [Double]?
    /// 生成を速くするために覚えたものを捨てる。次の未確定の文字列は前の文字列の計算を引き継がない
    func reset()
}

/// 生成の 1 つの要求。left に続く kana を生成する
struct GenerationRequest: Hashable {
    var left: String
    var kana: String
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
/// - convert が変換を返すかなと文脈には、display も必ず返す
final class DirectConverter: JapaneseConverting {
    private let scorer: any JapaneseConverting
    private let generator: any DirectDisplayGenerating
    /// 区間・文脈・左の文字列ごとの表示。Segmenter は 1 打鍵の中で同じ区間を何度も表示にするので、生成を 1 回にする。未確定の文字列の寿命だけ持つ
    private var displays: [DisplayRequest: JapaneseDisplay?] = [:]

    /// 文と左の文字列ごとの確からしさ。区切りが変わらない部分（句読点より前）は打鍵ごとに同じ文を測るので、1 回にする。未確定の文字列の寿命だけ持つ
    private var naturalnesses: [NaturalnessKey: Double] = [:]

    private struct NaturalnessKey: Hashable {
        var text: String
        var left: String
    }

    init(scorer: any JapaneseConverting, generator: any DirectDisplayGenerating) {
        self.scorer = scorer
        self.generator = generator
    }

    func convert(kana: String, context: JapaneseContext, ending: JapaneseEnding) -> JapaneseReading? {
        scorer.convert(kana: kana, context: context, ending: ending)
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] {
        scorer.alternatives(kana: kana, context: context)
    }

    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        displays([DisplayRequest(kana: kana, context: context, left: left)])[0]
    }

    /// 覚えていない要求だけを、まとめて生成するものに生成させる
    func displays(_ requests: [DisplayRequest]) -> [JapaneseDisplay?] {
        var missing: [(request: DisplayRequest, scored: JapaneseReading)] = []
        for request in requests where displays[request] == nil && !missing.contains(where: { $0.request == request }) {
            guard let scored = scorer.convert(kana: request.kana, context: request.context, ending: .open) else {
                displays[request] = .some(nil)
                continue
            }
            missing.append((request, scored))
        }
        let texts = generator.generate(missing.map { GenerationRequest(left: ZenzPrompt.leftContext(context: $0.request.context, left: $0.request.left), kana: $0.request.kana) })
        for ((request, scored), text) in zip(missing, texts) {
            var cuts: [Int] = []
            for scoredClause in scored.clauses.dropLast() { cuts.append((cuts.last ?? 0) + scoredClause.clause.reading.count) }
            let output = ReadingAlignment(text: text, reading: request.kana)?.clauses(cutAt: cuts) ?? [JapaneseClause(reading: request.kana, text: text)]
            let clauses = Self.keepingUserWords(output, scored: scored.clauses)
            displays[request] = JapaneseDisplay(text: clauses.map(\.text).joined(), clauses: clauses, userWords: scored.clauses.flatMap(\.userWords))
        }
        return requests.map { displays[$0]! }
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
            precondition(reading == clause.reading, "表示の文節が採点の文節の境目で切られていない: \(clause.reading) \(reading)")
            let words = covered.flatMap(\.userWords)
            guard !words.allSatisfy({ word in word.spellings.contains { clause.text.contains($0) } }) else { return clause }
            return JapaneseClause(reading: clause.reading, text: covered.map(\.clause.text).joined())
        }
    }

    var evaluatesSentences: Bool { true }

    /// 覚えていない文だけを、まとめて生成するものに測らせる。まとめて計算する組は浮動小数の丸めに効くので、texts に現れた順を保つ。
    /// 生成するものが測れない文（位置の上限に収まらない）を含めば nil
    func naturalness(texts: [String], left: String) -> [Double]? {
        var missing: [String] = []
        for text in texts where naturalnesses[NaturalnessKey(text: text, left: left)] == nil && !missing.contains(text) { missing.append(text) }
        if !missing.isEmpty {
            guard let values = generator.naturalness(left: left, texts: missing) else { return nil }
            for (text, value) in zip(missing, values) {
                naturalnesses[NaturalnessKey(text: text, left: left)] = value
            }
        }
        return texts.map { naturalnesses[NaturalnessKey(text: $0, left: left)]! }
    }

    func endComposition() {
        scorer.endComposition()
        generator.reset()
        displays = [:]
        naturalnesses = [:]
    }

    /// 生成するものは辞書を知らないが、未確定の文字列が終わるので、覚えた生成も捨てる
    func replaceUserWords(_ words: [UserWord]) {
        scorer.replaceUserWords(words)
        generator.reset()
        displays = [:]
        naturalnesses = [:]
    }
}
