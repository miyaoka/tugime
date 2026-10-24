import Foundation

/// 全体と 1 件ごとの時間の上限。変換エンジンの呼び出しは同期で途中から止められないので、
/// 上限を超えたら別のスレッドから、超えた件と経過時間を標準エラーに出してプロセスを終了コード 3 で終える。
/// 止めた時点までの進捗は 1 件ごとに出ているので、どこで止まったかは出力に残る
public final class Watchdog: @unchecked Sendable {
    public struct Limits: Sendable {
        public var total: Duration
        public var perItem: Duration
        /// 変換器を作ってモデルを読み込む 1 回の上限。辞書とモデルの読み込みは 1 件の変換より桁で長い
        public var load: Duration

        public init(total: Duration, perItem: Duration, load: Duration) {
            self.total = total
            self.perItem = perItem
            self.load = load
        }

        /// 精度: 593 問を 2 方式で。1 問は通常 1 秒未満
        public static let accuracy = Limits(total: .seconds(30 * 60), perItem: .seconds(30), load: .seconds(120))
        /// 打鍵: 1 打鍵は通常 100ms 未満
        public static let keystroke = Limits(total: .seconds(30 * 60), perItem: .seconds(5), load: .seconds(120))
    }

    /// 上限を超えたときの終了コード
    public static let timeoutExitCode: Int32 = 3
    /// 上限を見る間隔
    private static let pollInterval: TimeInterval = 0.1

    private let limits: Limits
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private let lock = NSLock()
    /// 数えている件。nil なら件の上限は見ない
    private var item: (name: String, started: ContinuousClock.Instant, limit: Duration)?
    private var finished = false

    /// 作った時点から total を数え始める。コマンドの最初に作る
    public init(limits: Limits) {
        self.limits = limits
        started = clock.now
        // スレッドは finish まで self を持つ
        let thread = Thread { self.watch() }
        thread.stackSize = 1 << 16
        thread.start()
    }

    /// この件の perItem を数え始める。前の件の数えは捨てる
    public func arm(item name: String) {
        arm(name, limit: limits.perItem)
    }

    /// 変換器を作る間を数え始める。上限は load
    public func armLoad(_ name: String) {
        arm(name, limit: limits.load)
    }

    private func arm(_ name: String, limit: Duration) {
        lock.withLock { item = (name, clock.now, limit) }
    }

    /// 記録を書き終えたら呼ぶ。以後は何も数えない
    public func finish() {
        lock.withLock { finished = true }
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            let now = clock.now
            let (done, current) = lock.withLock { (finished, item) }
            if done { return }
            if now - started > limits.total {
                stop("全体の上限 \(limits.total) を超えた（\(current?.name ?? "件の外")）")
            }
            if let current, now - current.started > current.limit {
                stop("\(current.name) が上限 \(current.limit) を超えた")
            }
        }
    }

    /// 変換エンジンが別のスレッドで動いている最中なので、終了の処理を走らせずに終える
    private func stop(_ message: String) -> Never {
        FileHandle.standardError.write(Data("時間の上限: \(message)\n".utf8))
        fflush(stdout)
        _exit(Self.timeoutExitCode)
    }
}
