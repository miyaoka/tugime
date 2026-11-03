@testable import TugimeCore

/// 全スイートで共有する、同梱の綴りの表・語表と、本物の変換器で組んだ Segmenter。
/// スイートの init で同梱の表を読まず、ここから取る。
/// 利用者の語や辞書を入れるスイートは、共有の converter と segmenter の状態を変えないよう、自分の変換器を作り、区切りが要るときは make に渡す
enum Shared {
    static let converter = LatticeConverter(dictionary: TestDictionary.shared)
    static let table = Result { try RomajiTable.bundled() }
    static let english = Result { try EnglishModel.bundled() }
    static let segmenter = Result { try make(converter) }

    static func make(_ japanese: JapaneseConverting) throws -> Segmenter {
        try Segmenter(table: table.get(), english: english.get(), japanese: japanese)
    }
}
