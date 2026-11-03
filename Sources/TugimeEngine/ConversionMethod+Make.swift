import Foundation
import TugimeCore

extension ConversionMethod {
    /// 同梱の綴りの表と語表で、この方式の区切りを作る。区切りはこれからだけ作る
    public func makeSegmenter(dictionary: SystemDictionary) throws -> Segmenter {
        try Segmenter(table: .bundled(), english: .bundled(), japanese: make(dictionary: dictionary))
    }

    /// 変換器を作り、モデルを読み込み終えた状態で返す。最初の変換で読み込みの時間が混ざらないよう、ここで先読みまで済ませる。
    /// モデルを読めなければプロセスごと止まる（fatalError。投げるエラーではないので、呼び出し元は受け止められない）
    public func make(dictionary: SystemDictionary) -> any JapaneseConverting {
        make(dictionary: dictionary) { ZenzGenerator(weight: $0) }
    }
}
