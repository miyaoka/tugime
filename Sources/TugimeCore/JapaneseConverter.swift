import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// かなを変換した最良の結果と、その言語モデル上の評価値
public struct JapaneseReading: Sendable, Equatable {
    public var text: String
    /// 変換エンジンの評価値。大きいほど自然
    public var value: Double
}

/// 日本語区間の前に何があるか
public enum JapaneseContext: Sendable, Hashable {
    /// 入力の先頭。文頭から始まる文として評価する
    case start
    /// 英語区間の直後。混在文の英語は名詞として働くので、名詞に続く形として評価する
    case afterEnglish
}

public protocol JapaneseConverting: AnyObject {
    func convert(kana: String, context: JapaneseContext) -> JapaneseReading?
}

/// AzooKeyKanaKanjiConverter による変換。学習は使わないので、同じかなには常に同じ結果を返す。
public final class AzooKeyConverter: JapaneseConverting {
    /// 英語区間の代わりに前へ置く名詞。辞書で 1 語に定まり、後ろの語と融合しにくいもの
    private static let nounStandIn = (kana: "てすと", word: "テスト")

    private let converter: KanaKanjiConverter
    private let options: ConvertRequestOptions
    private var cache: [CacheKey: JapaneseReading?] = [:]

    private struct CacheKey: Hashable {
        var kana: String
        var context: JapaneseContext
    }

    public init() {
        converter = KanaKanjiConverter.withDefaultDictionary()
        // 学習しないので書き込み先は使われないが、引数として要る
        let unused = FileManager.default.temporaryDirectory
        options = ConvertRequestOptions(
            N_best: 5,
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
        case .start: convertWhole(kana)
        case .afterEnglish: convertAfterNoun(kana)
        }
        cache[key] = result
        return result
    }

    private func candidates(_ kana: String) -> [Candidate] {
        var composing = ComposingText()
        composing.insertAtCursorPosition(kana, inputStyle: .direct)
        let kanaCount = kana.count
        // 入力全体を覆い、言語モデルで評価された候補だけを採る
        return converter.requestCandidates(composing, options: options).mainResults.filter {
            $0.rubyCount == kanaCount && !Self.isUnscoredWhole($0)
        }
    }

    /// 入力全体をカタカナ・ひらがな・大文字にしただけの候補。
    /// 言語モデルを通らない固定値が付き、カタカナは「プ」「ー」などを含むほど評価値が上がるので、日英の比較に使えない
    private static func isUnscoredWhole(_ candidate: Candidate) -> Bool {
        let unscoredMid = 501
        let properNounCid = 1288
        guard candidate.data.count == 1, let only = candidate.data.first else { return false }
        return only.mid == unscoredMid && only.lcid == properNounCid
    }

    private func convertWhole(_ kana: String) -> JapaneseReading? {
        candidates(kana).first.map { JapaneseReading(text: $0.text, value: Double($0.value)) }
    }

    /// 代わりの名詞を前に置いて変換し、名詞だけの評価値を差し引く
    private func convertAfterNoun(_ kana: String) -> JapaneseReading? {
        let standIn = Self.nounStandIn
        guard let nounOnly = candidates(standIn.kana).first(where: { $0.text == standIn.word }) else { return nil }
        // 辞書が名詞と後ろの語を 1 語にまとめることがあるので、語の切れ目ではなく文字列で名詞を外す
        guard let withNoun = candidates(standIn.kana + kana).first(where: { $0.text.hasPrefix(standIn.word) }) else { return nil }
        let text = String(withNoun.text.dropFirst(standIn.word.count))
        return JapaneseReading(text: text, value: Double(withNoun.value - nounOnly.value))
    }
}
