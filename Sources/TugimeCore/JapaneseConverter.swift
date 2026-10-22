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
    /// left は入力の中でこの区間より前に表示している文字列。context は afterCaret を渡さず、convert が返した context を渡す
    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseReading?
    /// 未確定の文字列を確定・取り消ししたときに、その文字列のために覚えたものを捨てる
    func endComposition()
}

/// AzooKeyKanaKanjiConverter による変換。学習は使わないので、同じかなには常に同じ結果を返す。
/// 採点は辞書と n-gram だけで行い、表示は Zenzai（ニューラルの言語モデル）で左の文脈を見て選び直す
public final class AzooKeyConverter: JapaneseConverting {
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
    private var displayCache: [DisplayKey: JapaneseReading?] = [:]
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

    public init(zenzaiWeight: URL?) {
        converter = KanaKanjiConverter.withDefaultDictionary()
        self.zenzaiWeight = zenzaiWeight
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
        candidates(kana, nBest: Self.scoringBest).first.map {
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

    public func display(kana: String, context: JapaneseContext, left: String) -> JapaneseReading? {
        guard let zenzaiWeight else { return convert(kana: kana, context: context) }
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
            prefix = Prefix(input: digits, shown: digits)
            leftContext = String(left.dropLast(digits.count))
        }
        let zenzai = ConvertRequestOptions.ZenzaiMode.on(
            weight: zenzaiWeight,
            personalizationMode: nil,
            versionDependentMode: .v3(.init(leftSideContext: leftContext.isEmpty ? nil : leftContext))
        )
        let result: JapaneseReading?
        if let prefix {
            result = candidates(prefix.input + kana, nBest: Self.scoringBest, zenzai: zenzai)
                .first { Self.drop(prefix, from: $0) != nil }
                .flatMap { candidate in
                    Self.drop(prefix, from: candidate).map { text in
                        JapaneseReading(text: text, value: Double(candidate.value), clauses: Self.clauses(of: Self.words(after: prefix, in: candidate), kana: kana, text: text), context: context)
                    }
                }
        } else {
            result = candidates(kana, nBest: Self.scoringBest, zenzai: zenzai).first.map {
                JapaneseReading(text: $0.text, value: Double($0.value), clauses: Self.clauses(of: $0.data[...], kana: kana, text: $0.text), context: context)
            }
        }
        // Zenzai が前に置いたものを含む候補を返さなかったときは、採点の変換を表示にする。区間は採点の変換があるときだけ日本語になる
        let shown = result ?? convert(kana: kana, context: context)
        displayCache[key] = shown
        return shown
    }

    public func endComposition() {
        cache = [:]
        prefixValues = [:]
        displayCache = [:]
    }

    private func candidates(_ kana: String, nBest: Int, zenzai: ConvertRequestOptions.ZenzaiMode = .off) -> [Candidate] {
        var composing = ComposingText()
        composing.insertAtCursorPosition(kana, inputStyle: .direct)
        let kanaCount = kana.count
        // 変換エンジンは直前の入力との差分で計算するので、前の要求の状態を捨て、要求ごとに独立した結果にする
        converter.stopComposition()
        // 入力全体を覆い、言語モデルで評価された候補だけを採る
        let results = converter.requestCandidates(composing, options: Self.options(nBest: nBest, zenzai: zenzai)).mainResults.filter {
            $0.rubyCount == kanaCount && !Self.isUnscoredWhole($0)
        }
        // 変換エンジンはモデルを読めないと黙って Zenzai なしで変換する。読めたときだけ zenzStatus が "load <URL>" になる
        if let zenzaiWeight, zenzai != .off, converter.zenzStatus != "load \(zenzaiWeight.absoluteString)" {
            fatalError("Zenzai のモデルを読めない: \(converter.zenzStatus)")
        }
        return results
    }

    /// 入力全体をカタカナ・ひらがな・大文字にしただけの候補。
    /// 言語モデルを通らない固定値が付き、カタカナは「プ」「ー」などを含むほど評価値が上がるので、日英の比較に使えない
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
        let value = candidates(prefix.input, nBest: Self.scoringBest).first.map { Double($0.value) }
        prefixValues[prefix.input] = value
        return value
    }

    /// 前に置いたものに続けて変換し、前に置いたものだけの評価値を差し引く
    private func convert(_ kana: String, after prefix: Prefix, context: JapaneseContext) -> JapaneseReading? {
        guard let prefixOnly = value(of: prefix),
              let combined = candidates(prefix.input + kana, nBest: Self.scoringBest).first(where: { Self.drop(prefix, from: $0) != nil }),
              let text = Self.drop(prefix, from: combined)
        else { return nil }
        let clauses = Self.clauses(of: Self.words(after: prefix, in: combined), kana: kana, text: text)
        return JapaneseReading(text: text, value: Double(combined.value) - prefixOnly, clauses: clauses, context: context)
    }
}
