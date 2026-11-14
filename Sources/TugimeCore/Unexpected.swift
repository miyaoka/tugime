import Foundation
import os

/// 想定外の状態の扱い。入力メソッドを止めると打っている途中の文字列が消えるので、想定外の状態に当たっても止めない。
/// 当たった箇所は `reached` で記録し、計算は渡した値で最後まで進める。入力メソッドは 1 つの操作を `guarded` で行い、
/// 途中で当たっていれば操作の結果を捨てて、打鍵と表示を操作の前のまま残す。デバッグビルドでは当たった箇所で止める
public enum Unexpected {
    /// 1 つの操作の中で当たった想定外の状態
    final class Record: Sendable {
        let messages = OSAllocatedUnfairLock(initialState: [String]())
    }

    @TaskLocal static var current: Record?

    /// デバッグビルドで当たった箇所で止めるか。止めずに `guarded` が結果を捨てることを確かめるテストだけが偽にする
    @TaskLocal static var stopsInDebug = true

    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tugime", category: "unexpected")

    /// 想定外の状態に当たったことを記録して value を返す。value は計算を最後まで進めるためだけの値で、操作の結果は `guarded` が捨てる。
    /// 文言には利用者の打鍵を含めうるので、ログでは伏せる
    static func reached<T>(_ message: @autoclosure () -> String, continuingWith value: T, file: StaticString = #fileID, line: UInt = #line) -> T {
        let text = message()
        logger.fault("想定外の状態（\(file, privacy: .public):\(line, privacy: .public)）: \(text, privacy: .private)")
        current?.messages.withLock { $0.append(text) }
        if stopsInDebug { assertionFailure(text, file: file, line: line) }
        return value
    }

    /// body を 1 つの操作として行う。途中で想定外の状態に当たれば、結果を捨てて nil を返す
    public static func guarded<T>(_ body: () throws -> T) rethrows -> T? {
        let record = Record()
        let result = try $current.withValue(record) { try body() }
        return record.messages.withLock(\.isEmpty) ? result : nil
    }
}
