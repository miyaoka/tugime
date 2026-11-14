import Foundation
import os

/// tugime のログの subsystem
public let logSubsystem = Bundle.main.bundleIdentifier ?? "tugime"

/// 想定外の状態の扱い。入力メソッドを止めると打っている途中の文字列が消えるので、想定外の状態に当たっても止めない。
/// 当たった箇所は `reached` で記録し、計算は渡した値で最後まで進める。入力メソッドは 1 つの操作を `guarded` で行い、
/// 途中で当たっていれば操作の結果を捨てて、打鍵と表示を操作の前のまま残す。当たった計算の結果は覚えない（`watching`）。
/// デバッグビルドでは当たった箇所で止める
public enum Unexpected {
    /// 1 つの範囲の中で当たった想定外の状態。外側の範囲があれば、当たったことを外側にも伝える
    final class Record: Sendable {
        let reached = OSAllocatedUnfairLock(initialState: false)
        let outer: Record?

        init(outer: Record?) {
            self.outer = outer
        }

        func mark() {
            reached.withLock { $0 = true }
            outer?.mark()
        }
    }

    @TaskLocal static var current: Record?

    /// デバッグビルドで当たった箇所で止めるか。止めずに `guarded` が結果を捨てることを確かめるテストだけが偽にする
    @TaskLocal static var stopsInDebug = true

    static let logger = Logger(subsystem: logSubsystem, category: "unexpected")

    /// 想定外の状態に当たったことを記録して value を返す。value は計算を最後まで進めるためだけの値で、操作の結果は `guarded` が捨てる。
    /// reason は利用者の入力を含まない理由の文で、ログに読める形で出す。detail は利用者の打鍵から来る値で、ログでは伏せる
    static func reached<T>(
        _ reason: String, detail: @autoclosure () -> String = "", continuingWith value: T, file: StaticString = #fileID, line: UInt = #line
    ) -> T {
        let shown = detail()
        logger.fault("想定外の状態（\(file, privacy: .public):\(line, privacy: .public)）: \(reason, privacy: .public) \(shown, privacy: .private)")
        current?.mark()
        if stopsInDebug { assertionFailure("\(reason) \(shown)", file: file, line: line) }
        return value
    }

    /// body を行い、その中で想定外の状態に当たったかを返す。当たったことは外側の範囲にも伝わる。
    /// 計算の結果を覚えるものは、当たっていなければだけ覚える
    static func watching<T>(_ body: () throws -> T) rethrows -> (value: T, reached: Bool) {
        let record = Record(outer: current)
        let value = try $current.withValue(record) { try body() }
        return (value, record.reached.withLock { $0 })
    }

    /// body を 1 つの操作として行う。途中で想定外の状態に当たれば、結果を捨てて nil を返す
    public static func guarded<T>(_ body: () throws -> T) rethrows -> T? {
        let (value, reached) = try watching(body)
        return reached ? nil : value
    }
}
