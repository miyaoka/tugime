import Foundation
import TugimeCore
import TugimeEngine

/// 区切りと変換を 1 本の直列キューで動かす。Segmenter はスレッド安全ではないので、Segmenter に触るのはこのキューの上だけにする。
/// 打鍵ごとの変換は待たずに積み、打鍵の処理を変換の重さから切り離す
nonisolated final class ConversionQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tugime.conversion", qos: .userInteractive)
    private let segmenter: Segmenter
    /// 区切りが使う綴りの表。変わらない値なので、キューの外から読んでよい
    let table: RomajiTable

    init(segmenter: Segmenter) {
        self.segmenter = segmenter
        table = segmenter.table
    }

    /// バンドルの Contents/Resources が無い
    struct MissingResources: Error, CustomStringConvertible {
        var description: String { "バンドルの Contents/Resources が無い" }
    }

    /// 入力メソッドの区切りと変換。表示の変換のモデルはバンドルの Contents/Resources/model に、システム辞書は Contents/Resources/dictionary に同梱する。
    /// 辞書・語表・モデルの読み込みが重いので、プロセスに 1 つだけ作る
    static func inputMethod() throws -> ConversionQueue {
        guard let resources = Bundle.main.resourceURL else { throw MissingResources() }
        let method = ConversionMethod.inputMethod(modelDirectory: resources.appendingPathComponent("model"))
        let dictionary = try SystemDictionary(url: resources.appendingPathComponent(SystemDictionary.directory).appendingPathComponent(SystemDictionary.fileName))
        return ConversionQueue(segmenter: try method.makeSegmenter(dictionary: dictionary))
    }

    /// 先に積んだ変換が終わるのを待ってから work を動かし、結果を返す。結果が無いと次に進めない操作（文節の選択・確定）に使う
    func sync<T>(_ work: (Segmenter) -> T) -> T {
        queue.sync { work(segmenter) }
    }

    /// 待たずに積む
    func async(_ work: @escaping @Sendable (Segmenter) -> Void) {
        queue.async { work(self.segmenter) }
    }
}
