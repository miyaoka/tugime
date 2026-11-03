import Foundation
import TugimeCore

/// llama.cpp で zenz 形式のモデルを動かす生成器を作る。ConversionMethod の make と makeSegmenter に渡す
package func modelGenerator(weight: URL) -> any DirectDisplayGenerating { ZenzGenerator(weight: weight) }

extension ConversionMethod {
    /// ConversionMethod.makeSegmenter(dictionary:generator:) に、llama.cpp でモデルを動かす生成器を渡したもの
    public func makeSegmenter(dictionary: SystemDictionary) throws -> Segmenter {
        try makeSegmenter(dictionary: dictionary, generator: modelGenerator(weight:))
    }

    /// ConversionMethod.make(dictionary:generator:) に、llama.cpp でモデルを動かす生成器を渡したもの
    public func make(dictionary: SystemDictionary) -> any JapaneseConverting {
        make(dictionary: dictionary, generator: modelGenerator(weight:))
    }
}
