import Foundation
@testable import TugimeCore

/// テストが読むシステム辞書。bun scripts/fetch-dictionary.ts がリポジトリの直下に組み立てたもの。読むだけなので全テストで共有する
enum TestDictionary {
    static let shared: SystemDictionary = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        do { return try SystemDictionary(url: SystemDictionary.inRepository(root)) } catch { fatalError("\(error)") }
    }()
}

/// 本物の変換器と、同梱の綴りの表・語表で組んだ Segmenter。表を読むのは重いので、全スイートで 1 回だけ読む。
/// 利用者の辞書を入れるスイートは、共有の converter と segmenter の状態を変えないよう、make で別に作る
enum Shared {
    static let converter = LatticeConverter(dictionary: TestDictionary.shared)
    static let table = Result { try RomajiTable.bundled() }
    static let english = Result { try EnglishModel.bundled() }
    static let segmenter = Result { try make(converter) }

    static func make(_ japanese: JapaneseConverting) throws -> Segmenter {
        try Segmenter(table: table.get(), english: english.get(), japanese: japanese)
    }
}
