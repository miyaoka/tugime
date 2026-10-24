import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// かなを変換した最良の結果と、その言語モデル上の評価値
public struct JapaneseReading: Sendable, Equatable {
    public var text: String
    /// 変換エンジンの評価値。大きいほど自然
    public var value: Double
    /// text を文節に分けたもの。読みを繋ぐと変換したかなに、表記を繋ぐと text になる
    public var clauses: [JapaneseClause]
    /// この変換を読んだ文脈。afterCaret は文頭か前の語に続く形のどちらかに決まり、それ以外は求めたとおり
    public var context: JapaneseContext

    public init(text: String, value: Double, clauses: [JapaneseClause], context: JapaneseContext) {
        self.text = text
        self.value = value
        self.clauses = clauses
        self.context = context
    }
}

/// 表示の変換の結果。評価値を持たないので、区切りの採点には使えない
public struct JapaneseDisplay: Sendable, Equatable {
    public var text: String
    /// text を文節に分けたもの。読みを繋ぐと変換したかなに、表記を繋ぐと text になる
    public var clauses: [JapaneseClause]

    public init(text: String, clauses: [JapaneseClause]) {
        self.text = text
        self.clauses = clauses
    }
}

/// 変換結果の 1 文節
public struct JapaneseClause: Sendable, Equatable {
    public var reading: String
    public var text: String

    public init(reading: String, text: String) {
        self.reading = reading
        self.text = text
    }
}

/// 日本語区間をどの位置にあるものとして評価するか
public enum JapaneseContext: Sendable, Hashable {
    /// 文頭から始まる文として評価する
    case start
    /// 前の語に続く形として評価する。英語区間の直後（混在文の英語は名詞として働く）
    case afterWord
    /// 入力欄のカーソルの前にある文字に続けて打ち始めたときの形。前の文字が文のどこに当たるかは分からないので、
    /// 前の語に続く形と新しく始まる形のうち自然な方で評価する。convert だけが受け取り、どちらの形で読んだかを結果の context で返す
    case afterCaret
    /// 数字に続く形として評価する。数字は変換エンジンがそのまま扱えるので、助数詞（円・回・個）として読ませる
    case afterNumber(String)
}

public protocol JapaneseConverting: AnyObject {
    /// 区切りの採点に使う最良の変換
    func convert(kana: String, context: JapaneseContext) -> JapaneseReading?
    /// 候補の窓に並べる変換結果。評価値の高い順で、重複は除く。件数は変換エンジンが決める。context に afterCaret は渡さず、convert が返した context を渡す
    func alternatives(kana: String, context: JapaneseContext) -> [String]
    /// 区切りが決まった区間を表示するための変換。採点のように何百回も呼ばないので、重くて質の高い変換を使ってよい。
    /// left は入力の中でこの区間より前に表示している文字列。context は afterCaret を渡さず、convert が返した context を渡す。
    /// convert が変換を返すかなと文脈には、必ず変換を返す
    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay?
    /// 未確定の文字列を確定・取り消ししたときに、その文字列のために覚えたものを捨てる
    func endComposition()
}

/// AzooKeyKanaKanjiConverter による変換。学習は使わないので、同じかなには常に同じ結果を返す。
/// 採点は辞書と n-gram だけで行い、表示は Zenzai（ニューラルの言語モデル）で左の文脈を見て選び直す
final class AzooKeyConverter: JapaneseConverting {
    /// 英語区間の代わりに前へ置く名詞。辞書で 1 語に定まり、後ろの語と融合しにくいもの
    private static let nounStandIn = (kana: "てすと", word: "テスト")
    /// 変換エンジンに求める上位の数。採点は区間ごとに何百回も呼ぶので少なくする。
    /// 候補の窓は多めに求めるが、変換エンジンは単語の候補も足すので、返る件数はこれと一致しない
    private static let scoringBest = 5
    private static let listingBest = 20

    private let converter: KanaKanjiConverter
    /// Zenzai のモデル。nil なら表示も採点と同じ変換にする
    private let zenzaiWeight: URL?
    /// 表示の変換を、区間・文脈・左の文字列ごとに覚える。未確定の文字列の寿命だけ持つ
    private var displayCache: [DisplayKey: JapaneseDisplay?] = [:]
    /// 打鍵のたびに同じ区間を変換し直さないためのもの。未確定の文字列の寿命だけ持つ
    private var cache: [CacheKey: JapaneseReading?] = [:]
    /// 前に置くものだけを変換した評価値。未確定の文字列の寿命だけ持つ
    private var prefixValues: [String: Double?] = [:]

    /// かなの前に置いて文脈にするもの。input は変換エンジンに渡す形、shown は変換結果の先頭に現れる形
    private struct Prefix {
        var input: String
        var shown: String
    }

    private static let standIn = Prefix(input: nounStandIn.kana, shown: nounStandIn.word)

    private static func prefix(for context: JapaneseContext) -> Prefix? {
        switch context {
        case .start: nil
        case .afterWord: standIn
        case .afterCaret: preconditionFailure("afterCaret は convert で文頭か前の語に続く形に決めてから渡す")
        case .afterNumber(let digits): Prefix(input: digits, shown: digits)
        }
    }

    private struct CacheKey: Hashable {
        var kana: String
        var context: JapaneseContext
    }

    private struct DisplayKey: Hashable {
        var kana: String
        var context: JapaneseContext
        var left: String
    }

    /// 採点に使うセッションの数。区切りは打鍵のたびに、同じ開始位置の読みを 1 かなずつ伸ばして採点するので、
    /// 開始位置と文脈の組ごとにセッションがあれば、変換エンジンが前の読みの途中の計算を使い回せる
    private static let scoringSessionCount = 32

    /// 採点に使うセッションと、それぞれに前に渡した読み
    private var scoringSessions: [(id: KanaKanjiConverter.ConversionSessionID, last: String, used: Int)] = []
    private var scoringClock = 0

    init(zenzaiWeight: URL?) {
        converter = KanaKanjiConverter.withDefaultDictionary()
        self.zenzaiWeight = zenzaiWeight
    }

    /// 採点のセッションを選ぶ。前に渡した読みが text の先頭と一致するセッションがあればそれを使い、
    /// 無ければ一番長く使っていないセッションを作り直して使う
    private func scoringSession(for text: String) -> KanaKanjiConverter.ConversionSessionID {
        scoringClock += 1
        let continuing = scoringSessions.indices.filter { text.hasPrefix(scoringSessions[$0].last) }
        let index: Int
        if let longest = continuing.max(by: { scoringSessions[$0].last.count < scoringSessions[$1].last.count }) {
            index = longest
        } else if scoringSessions.count < Self.scoringSessionCount {
            scoringSessions.append((converter.createSession(), text, scoringClock))
            index = scoringSessions.count - 1
        } else {
            index = scoringSessions.indices.min { scoringSessions[$0].used < scoringSessions[$1].used }!
            converter.removeSession(scoringSessions[index].id)
            scoringSessions[index].id = converter.createSession()
        }
        scoringSessions[index].last = text
        scoringSessions[index].used = scoringClock
        return scoringSessions[index].id
    }

    private static func options(nBest: Int, zenzai: ConvertRequestOptions.ZenzaiMode) -> ConvertRequestOptions {
        // 学習しないので書き込み先は使われないが、引数として要る
        let unused = FileManager.default.temporaryDirectory
        return ConvertRequestOptions(
            N_best: nBest,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            learningType: .nothing,
            memoryDirectoryURL: unused,
            sharedContainerURL: unused,
            textReplacer: .empty,
            specialCandidateProviders: [],
            zenzaiMode: zenzai,
            // 打ち間違いの補正は別の読みの語を出し、日英の比較を乱す
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }

    public func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        let key = CacheKey(kana: kana, context: context)
        if let cached = cache[key] { return cached }
        let result: JapaneseReading?
        switch context {
        case .start:
            result = convertAtStart(kana)
        case .afterWord:
            result = convert(kana, after: Self.standIn, context: context)
        case .afterCaret:
            // 前に置いた名詞は後ろの語と複合語（テスト用）を作るので、続く形だけで比べると新しく始まる読みを不当に下げる
            let candidates = [convertAtStart(kana), convert(kana, after: Self.standIn, context: .afterWord)].compactMap { $0 }
            result = candidates.max { $0.value < $1.value }
        case .afterNumber(let digits):
            result = convert(kana, after: Prefix(input: digits, shown: digits), context: context)
        }
        cache[key] = result
        return result
    }

    private func convertAtStart(_ kana: String) -> JapaneseReading? {
        candidates(kana, nBest: Self.scoringBest, scoring: true).first.map {
            JapaneseReading(text: $0.text, value: Double($0.value), clauses: Self.clauses(of: $0.data[...], kana: kana, text: $0.text), context: .start)
        }
    }

    public func alternatives(kana: String, context: JapaneseContext) -> [String] {
        let texts: [String]
        if let prefix = Self.prefix(for: context) {
            texts = candidates(prefix.input + kana, nBest: Self.listingBest).compactMap { Self.drop(prefix, from: $0) }
        } else {
            texts = candidates(kana, nBest: Self.listingBest).map(\.text)
        }
        var seen: Set<String> = []
        return texts.filter { seen.insert($0).inserted }
    }

    public func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        guard let zenzaiWeight else { return scoredDisplay(kana: kana, context: context) }
        let key = DisplayKey(kana: kana, context: context, left: left)
        if let cached = displayCache[key] { return cached }
        // 左に文字列があれば、それを Zenzai に文脈として渡すので仮の名詞は置かない。数字は助数詞として読ませるため入力の前に置き、文脈からは外す
        let prefix: Prefix?
        var leftContext = left
        switch context {
        case .start: prefix = nil
        case .afterWord: prefix = left.isEmpty ? Self.standIn : nil
        case .afterCaret: preconditionFailure("afterCaret は convert で文頭か前の語に続く形に決めてから渡す")
        case .afterNumber(let digits):
            // 数字は、未確定の文字列の中にあれば left の末尾にある。確定して入力欄に出ていれば、left は空になる
            precondition(left.isEmpty || left.hasSuffix(digits), "数字に続く区間の左の文字列が、その数字で終わっていない: \(left) \(digits)")
            prefix = Prefix(input: digits, shown: digits)
            leftContext = String(left.dropLast(digits.count))
        }
        let zenzai = Self.zenzai(weight: zenzaiWeight, left: leftContext)
        let result: JapaneseDisplay?
        if let prefix {
            result = candidates(prefix.input + kana, nBest: Self.scoringBest, zenzai: zenzai)
                .first { Self.drop(prefix, from: $0) != nil }
                .flatMap { candidate in
                    Self.drop(prefix, from: candidate).map { text in
                        JapaneseDisplay(text: text, clauses: Self.clauses(of: Self.words(after: prefix, in: candidate), kana: kana, text: text))
                    }
                }
        } else {
            result = candidates(kana, nBest: Self.scoringBest, zenzai: zenzai).first.map {
                JapaneseDisplay(text: $0.text, clauses: Self.clauses(of: $0.data[...], kana: kana, text: $0.text))
            }
        }
        // Zenzai の候補が表示に使えないときは、採点の変換を表示にする。使えないのは、前に置いたものを含む候補が無いときと、
        // 前に置くものが無くても入力全体を覆う候補が無いとき
        let shown = result ?? scoredDisplay(kana: kana, context: context)
        displayCache[key] = shown
        return shown
    }

    /// 採点の変換を表示の形にしたもの
    private func scoredDisplay(kana: String, context: JapaneseContext) -> JapaneseDisplay? {
        convert(kana: kana, context: context).map { JapaneseDisplay(text: $0.text, clauses: $0.clauses) }
    }

    /// 先読みで Zenzai に渡すかな。モデルを読ませるためだけのもので、結果は使わない
    private static let preloadKana = "にほんご"

    /// Zenzai のモデルを読み込む。変換エンジンはモデルを最初の Zenzai の要求で読むので、固定のかなで 1 回要求する。
    /// モデルを読めなければ止まる。変換器は ConversionMethod.make() が作り、そこで呼ぶ
    func preloadZenzai() {
        guard let zenzaiWeight else { preconditionFailure("Zenzai のモデルを渡していない変換器で先読みした") }
        _ = candidates(Self.preloadKana, nBest: 1, zenzai: Self.zenzai(weight: zenzaiWeight, left: ""))
    }

    private static func zenzai(weight: URL, left: String) -> ConvertRequestOptions.ZenzaiMode {
        .on(weight: weight, personalizationMode: nil, versionDependentMode: .v3(.init(leftSideContext: left.isEmpty ? nil : left)))
    }

    public func endComposition() {
        cache = [:]
        prefixValues = [:]
        displayCache = [:]
    }

    /// 変換エンジンは直前の入力との差分で計算する。採点は前に渡した読みの続きを同じセッションに渡して途中の計算を使い回す。
    /// 表示と候補の窓は前の状態を捨てて、要求ごとに独立した結果にする。Zenzai は前の変換で選んだ表記を次の探索の制約に引き継ぎ、
    /// 候補の窓は採点と上位の数が違うので、採点の途中の計算を共有できない
    private func candidates(_ kana: String, nBest: Int, zenzai: ConvertRequestOptions.ZenzaiMode = .off, scoring: Bool = false) -> [Candidate] {
        var composing = ComposingText()
        composing.insertAtCursorPosition(kana, inputStyle: .direct)
        let kanaCount = kana.count
        let request = { self.converter.requestCandidates(composing, options: Self.options(nBest: nBest, zenzai: zenzai)) }
        let result: ConversionResult
        if scoring {
            // セッションは採点が作ったものだけなので、見つからないことは無い
            result = try! converter.withSession(scoringSession(for: kana), operation: request)
        } else {
            converter.stopComposition()
            result = request()
        }
        // 入力全体を覆い、言語モデルで評価された候補だけを採る
        let results = result.mainResults.filter {
            $0.rubyCount == kanaCount && !Self.isUnscoredWhole($0)
        }
        // 変換エンジンはモデルを読めないと黙って Zenzai なしで変換する。読めたときだけ zenzStatus が "load <URL>" になる
        if let zenzaiWeight, zenzai != .off, converter.zenzStatus != "load \(zenzaiWeight.absoluteString)" {
            fatalError("Zenzai のモデルを読めない: \(converter.zenzStatus)")
        }
        return results
    }

    /// 入力全体をカタカナ・ひらがな・大文字にしただけの候補。言語モデルを通らない固定値が付く。
    /// 採点では、カタカナは「プ」「ー」などを含むほど評価値が上がるので、日英の比較に使えない。
    /// 表示では、Zenzai が並べ替えるのは文全体の変換の上位だけで、これらはその後ろに固定値のまま足される。
    /// 前に置いた仮の名詞と数字はカタカナにしても先頭に残るので、文全体の変換が前に置いたものを保たないときや文全体の変換が無いときに、
    /// 除かなければ言語モデルも Zenzai も通らない候補を表示に選ぶ
    private static func isUnscoredWhole(_ candidate: Candidate) -> Bool {
        guard candidate.data.count == 1, let only = candidate.data.first else { return false }
        return only.mid == MIDData.一般.mid && only.lcid == CIDData.固有名詞.cid
    }

    /// 語の列を、変換エンジンが文節の境目とする位置で切る。
    /// 語の列が text と読みに一致しない（前に置いたものと 1 語にまとまった、表記を書き換える語を含む）ときは、境目が分からないので全体を 1 文節にする
    private static func clauses(of words: ArraySlice<DicdataElement>?, kana: String, text: String) -> [JapaneseClause] {
        let whole = [JapaneseClause(reading: kana, text: text)]
        guard let words, words.map(\.ruby.count).reduce(0, +) == kana.count else { return whole }
        var rest = words
        var restKana = Substring(kana)
        var clauses: [JapaneseClause] = []
        while !rest.isEmpty {
            let first = Candidate.makePrefixClauseCandidate(data: rest)
            precondition(!first.data.isEmpty, "文節が空になった: \(kana)")
            clauses.append(JapaneseClause(reading: String(restKana.prefix(first.rubyCount)), text: first.text))
            rest = rest.dropFirst(first.data.count)
            restKana = restKana.dropFirst(first.rubyCount)
        }
        return clauses.map(\.text).joined() == text ? clauses : whole
    }

    /// 前に置いたものに当たる語を外した残り。前に置いたものと後ろの語が 1 語にまとまっていれば、語の切れ目で外せないので nil
    private static func words(after prefix: Prefix, in candidate: Candidate) -> ArraySlice<DicdataElement>? {
        let prefixCount = prefix.input.count
        var covered = 0
        var rest = candidate.data[...]
        while covered < prefixCount, let first = rest.first {
            covered += first.ruby.count
            rest = rest.dropFirst()
        }
        return covered == prefixCount ? rest : nil
    }

    /// 辞書が前に置いたものと後ろの語を 1 語にまとめることがあるので、語の切れ目ではなく文字列で外す
    private static func drop(_ prefix: Prefix, from candidate: Candidate) -> String? {
        guard candidate.text.hasPrefix(prefix.shown) else { return nil }
        let rest = String(candidate.text.dropFirst(prefix.shown.count))
        return rest.isEmpty ? nil : rest
    }

    /// 前に置くものだけの評価値。差し引きたいのは前に置いたものがある確からしさなので、表記（3 と 三）は問わず最良の候補で測る
    private func value(of prefix: Prefix) -> Double? {
        if let cached = prefixValues[prefix.input] { return cached }
        let value = candidates(prefix.input, nBest: Self.scoringBest, scoring: true).first.map { Double($0.value) }
        prefixValues[prefix.input] = value
        return value
    }

    /// 前に置いたものに続けて変換し、前に置いたものだけの評価値を差し引く
    private func convert(_ kana: String, after prefix: Prefix, context: JapaneseContext) -> JapaneseReading? {
        guard let prefixOnly = value(of: prefix),
              let combined = candidates(prefix.input + kana, nBest: Self.scoringBest, scoring: true).first(where: { Self.drop(prefix, from: $0) != nil }),
              let text = Self.drop(prefix, from: combined)
        else { return nil }
        let clauses = Self.clauses(of: Self.words(after: prefix, in: combined), kana: kana, text: text)
        return JapaneseReading(text: text, value: Double(combined.value) - prefixOnly, clauses: clauses, context: context)
    }
}
