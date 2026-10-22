import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// かなを変換した最良の結果と、その言語モデル上の評価値
public struct JapaneseReading: Sendable, Equatable {
    public var text: String
    /// 変換エンジンの評価値。大きいほど自然
    public var value: Double
}

/// 日本語区間をどの位置にあるものとして評価するか
public enum JapaneseContext: Sendable, Hashable {
    /// 文頭から始まる文として評価する
    case start
    /// 前の語に続く形として評価する。英語区間の直後（混在文の英語は名詞として働く）と、入力欄の文の途中から打ち始めたとき
    case afterWord
}

public protocol JapaneseConverting: AnyObject {
    /// 区切りの採点に使う最良の変換
    func convert(kana: String, context: JapaneseContext) -> JapaneseReading?
    /// 候補の窓に並べる変換結果。評価値の高い順で、重複は除く。件数は変換エンジンが決める
    func alternatives(kana: String, context: JapaneseContext) -> [String]
    /// 未確定の文字列を確定・取り消ししたときに、その文字列のために覚えたものを捨てる
    func endComposition()
}

/// AzooKeyKanaKanjiConverter による変換。学習は使わないので、同じかなには常に同じ結果を返す。
public final class AzooKeyConverter: JapaneseConverting {
    /// 英語区間の代わりに前へ置く名詞。辞書で 1 語に定まり、後ろの語と融合しにくいもの
    private static let nounStandIn = (kana: "てすと", word: "テスト")
    /// 変換エンジンに求める上位の数。採点は区間ごとに何百回も呼ぶので少なくする。
    /// 候補の窓は多めに求めるが、変換エンジンは単語の候補も足すので、返る件数はこれと一致しない
    private static let scoringBest = 5
    private static let listingBest = 20

    private let converter: KanaKanjiConverter
    /// 打鍵のたびに同じ区間を変換し直さないためのもの。未確定の文字列の寿命だけ持つ
    private var cache: [CacheKey: JapaneseReading?] = [:]
    /// 代わりの名詞だけを変換した評価値。入力によらないので 1 度だけ求める
    private lazy var nounStandInValue: Double? = candidates(Self.nounStandIn.kana, nBest: Self.scoringBest)
        .first { $0.text == Self.nounStandIn.word }
        .map { Double($0.value) }

    private struct CacheKey: Hashable {
        var kana: String
        var context: JapaneseContext
    }

    public init() {
        converter = KanaKanjiConverter.withDefaultDictionary()
    }

    private static func options(nBest: Int) -> ConvertRequestOptions {
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
            // 打ち間違いの補正は別の読みの語を出し、日英の比較を乱す
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }

    public func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        let key = CacheKey(kana: kana, context: context)
        if let cached = cache[key] { return cached }
        let result: JapaneseReading? = switch context {
        case .start:
            candidates(kana, nBest: Self.scoringBest).first.map { JapaneseReading(text: $0.text, value: Double($0.value)) }
        case .afterWord:
            convertAfterNoun(kana)
        }
        cache[key] = result
        return result
    }

    public func alternatives(kana: String, context: JapaneseContext) -> [String] {
        let texts: [String] = switch context {
        case .start:
            candidates(kana, nBest: Self.listingBest).map(\.text)
        case .afterWord:
            candidates(Self.nounStandIn.kana + kana, nBest: Self.listingBest).compactMap(Self.dropNounStandIn)
        }
        var seen: Set<String> = []
        return texts.filter { seen.insert($0).inserted }
    }

    public func endComposition() {
        cache = [:]
    }

    private func candidates(_ kana: String, nBest: Int) -> [Candidate] {
        var composing = ComposingText()
        composing.insertAtCursorPosition(kana, inputStyle: .direct)
        let kanaCount = kana.count
        // 変換エンジンは直前の入力との差分で計算するので、前の要求の状態を捨て、要求ごとに独立した結果にする
        converter.stopComposition()
        // 入力全体を覆い、言語モデルで評価された候補だけを採る
        return converter.requestCandidates(composing, options: Self.options(nBest: nBest)).mainResults.filter {
            $0.rubyCount == kanaCount && !Self.isUnscoredWhole($0)
        }
    }

    /// 入力全体をカタカナ・ひらがな・大文字にしただけの候補。
    /// 言語モデルを通らない固定値が付き、カタカナは「プ」「ー」などを含むほど評価値が上がるので、日英の比較に使えない
    private static func isUnscoredWhole(_ candidate: Candidate) -> Bool {
        guard candidate.data.count == 1, let only = candidate.data.first else { return false }
        return only.mid == MIDData.一般.mid && only.lcid == CIDData.固有名詞.cid
    }

    /// 辞書が名詞と後ろの語を 1 語にまとめることがあるので、語の切れ目ではなく文字列で名詞を外す
    private static func dropNounStandIn(_ candidate: Candidate) -> String? {
        guard candidate.text.hasPrefix(nounStandIn.word) else { return nil }
        let rest = String(candidate.text.dropFirst(nounStandIn.word.count))
        return rest.isEmpty ? nil : rest
    }

    /// 代わりの名詞を前に置いて変換し、名詞だけの評価値を差し引く
    private func convertAfterNoun(_ kana: String) -> JapaneseReading? {
        guard let nounOnly = nounStandInValue,
              let withNoun = candidates(Self.nounStandIn.kana + kana, nBest: Self.scoringBest).first(where: { Self.dropNounStandIn($0) != nil }),
              let text = Self.dropNounStandIn(withNoun)
        else { return nil }
        return JapaneseReading(text: text, value: Double(withNoun.value) - nounOnly)
    }
}
