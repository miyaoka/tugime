import Foundation
import TugimeCore

/// 区切りと変換を 1 本の直列キューで動かす。Segmenter はスレッド安全ではないので、Segmenter に触るのはこのキューの上だけにする。
/// 打鍵ごとの変換は待たずに積み、打鍵の処理を変換の重さから切り離す
nonisolated final class ConversionQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tugime.conversion", qos: .userInteractive)
    private let segmenter: Segmenter

    init(segmenter: Segmenter) {
        self.segmenter = segmenter
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
