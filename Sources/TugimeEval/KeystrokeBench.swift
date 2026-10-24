import Foundation
import TugimeCore

/// 打鍵の性能を測る 1 文。読みを利用者の綴りの表で逆にたどった打鍵列と、打鍵ごとの打ち終えた読みの文字数を持つ
public struct KeystrokeScript: Sendable {
    public var id: String
    public var reading: String
    public var spelled: [SpelledKana]
    /// spelled の keys を繋いだもの
    public var keys: String

    init(id: String, reading: String, spelled: [SpelledKana]) {
        self.id = id
        self.reading = reading
        self.spelled = spelled
        keys = spelled.map(\.keys).joined()
    }

    /// 選んだ文と、綴りで書けない文字（全角の括弧など）を含むので外した問題
    public struct Selection: Sendable {
        public var scripts: [KeystrokeScript]
        public var skipped: [Problem]
    }

    /// AJIMEE-Bench の問題のうち left が空のもの（入力欄の前に文字の無い打ち始め）を、問題ファイルの順に全部使う。
    /// 綴りで書けない文字を含む問題は外して返す。外した数は呼び出し元が出す
    public static func select(from problems: [Problem], table: RomajiTable) -> Selection {
        var selection = Selection(scripts: [], skipped: [])
        for problem in problems where problem.set == "ajimee" && problem.left.isEmpty {
            guard let spelled = Segmenter.spelling(of: problem.kana, table: table) else {
                selection.skipped.append(problem)
                continue
            }
            selection.scripts.append(KeystrokeScript(id: problem.id, reading: problem.kana, spelled: spelled))
        }
        return selection
    }

    /// 打鍵ごとの、その打鍵までに打ち終えた読みの文字数。読みの長さ別の集計の軸
    var kanaCounts: [Int] {
        var counts: [Int] = []
        var done = 0
        for item in spelled {
            counts += Array(repeating: done, count: item.keys.count - 1)
            done += item.kana.count
            counts.append(done)
        }
        return counts
    }
}

/// 打鍵の性能の実行。1 つの方式を 1 プロセスで測る。
/// ピークのメモリはプロセスの最大常駐量で測るので、同じプロセスで別の方式（基準も含む）の変換器を作らない。精度の実行とは逆の判断である
public enum KeystrokeBench {
    public struct Sample: Sendable {
        public var scriptID: String
        /// 何打鍵目か（1 始まり）
        public var keystroke: Int
        public var kanaCount: Int
        public var seconds: Double
    }

    public struct Report: Sendable {
        public var method: String
        /// ConversionMethod.make() と区切りの準備にかかった時間。辞書の読み込みとモデルの先読みを含む
        public var loadSeconds: Double
        /// 読み込み直後と、全打鍵の後の最大常駐量（getrusage の ru_maxrss、macOS はバイト）
        public var peakBytesAfterLoad: Int
        public var peakBytes: Int
        public var skipped: Int
        public var samples: [Sample]
        /// 文ごとの打鍵列と最後の liveText。`tugime-cli --live <打鍵列>` と一致するはずのもの
        public var finalTexts: [(keys: String, liveText: String)]
    }

    public enum Failure: Error, CustomStringConvertible {
        case keystrokeCountMismatch(samples: Int, keys: Int)
        public var description: String {
            switch self {
            case .keystrokeCountMismatch(let samples, let keys): "打鍵の回数 \(samples) が打鍵列の長さの合計 \(keys) と一致しない"
            }
        }
    }

    /// 不変条件:
    /// - 文ごとに、打鍵列の先頭 1 文字から全体まで 1 打鍵ずつ伸ばして liveText(prefix, leading: .start) を呼ぶ。入力メソッドが打鍵ごとに呼ぶのと同じ
    /// - 文の前に endComposition を呼ぶ。文の中では呼ばない（入力メソッドは打ち終えるまで覚えを持ち越す）
    /// - samples.count は全文の keys.count の和に等しい。終わりに確かめ、違えば止める
    public static func run(
        selection: KeystrokeScript.Selection,
        method: ConversionMethod,
        watchdog: Watchdog,
        progress: (String) -> Void
    ) throws -> Report {
        let clock = ContinuousClock()
        let loadStart = clock.now
        watchdog.armLoad("読み込み \(method.spec)")
        let segmenter = try Segmenter(table: .bundled(), english: .bundled(), japanese: method.make())
        let loadSeconds = seconds(clock.now - loadStart)
        let peakAfterLoad = maxResidentBytes()
        progress("変換器の読み込み \(String(format: "%.2f", loadSeconds))s、文 \(selection.scripts.count) 件（綴りで書けず外した文 \(selection.skipped.count) 件）")

        var samples: [Sample] = []
        var finalTexts: [(keys: String, liveText: String)] = []
        for (n, script) in selection.scripts.enumerated() {
            segmenter.endComposition()
            let keys = Array(script.keys)
            let kanaCounts = script.kanaCounts
            var last = ""
            var slowest = 0.0
            for i in 1...keys.count {
                watchdog.arm(item: "\(script.id) の \(i) 打鍵目")
                let start = clock.now
                last = segmenter.liveText(String(keys[..<i]), leading: .start)
                let elapsed = seconds(clock.now - start)
                slowest = max(slowest, elapsed)
                samples.append(Sample(scriptID: script.id, keystroke: i, kanaCount: kanaCounts[i - 1], seconds: elapsed))
            }
            finalTexts.append((script.keys, last))
            progress("[\(n + 1)/\(selection.scripts.count)] \(script.id) \(keys.count) 打鍵 最大 \(String(format: "%.1f", slowest * 1000))ms")
        }
        segmenter.endComposition()
        let keyCount = selection.scripts.map(\.keys.count).reduce(0, +)
        guard samples.count == keyCount else { throw Failure.keystrokeCountMismatch(samples: samples.count, keys: keyCount) }
        return Report(
            method: method.spec, loadSeconds: loadSeconds, peakBytesAfterLoad: peakAfterLoad, peakBytes: maxResidentBytes(),
            skipped: selection.skipped.count, samples: samples, finalTexts: finalTexts
        )
    }
}

/// 時間の分布
public struct LatencyStats: Sendable {
    public var count: Int
    public var median: Double
    public var p90: Double
    public var p99: Double
    public var max: Double

    /// 分位点は最近傍順位法（ceil(p * n) 番目）。補間しないので、出る値は必ずどれかの打鍵の実測値。空なら止める
    public init(_ seconds: [Double]) {
        precondition(!seconds.isEmpty, "時間の分布を空の列から作った")
        let sorted = seconds.sorted()
        func rank(_ p: Double) -> Double { sorted[Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
        count = sorted.count
        median = rank(0.5)
        p90 = rank(0.9)
        p99 = rank(0.99)
        max = sorted.last!
    }
}

extension KeystrokeBench.Report {
    /// 読みの長さの区切り。打ち終えた読みの文字数を、この幅でまとめる
    public static let kanaBucketWidth = 10

    /// 先頭に 方式・読み込み秒・最大常駐量・文と打鍵の数。続いて列の名前と、全体の行と読みの文字数の区切りごとの行。
    /// 列: 区切り 打鍵数 中央値 90% 99% 最大（ms）
    public var lines: [String] {
        let mib = { (bytes: Int) in String(format: "%.1fMiB", Double(bytes) / 1_048_576) }
        let keyCount = finalTexts.map(\.keys.count).reduce(0, +)
        var lines = [
            "方式\t\(method)",
            "読み込み\t\(String(format: "%.2f", loadSeconds))s",
            "最大常駐量\t読み込み直後 \(mib(peakBytesAfterLoad))\t全打鍵の後 \(mib(peakBytes))",
            "文\t\(finalTexts.count) 件（外した文 \(skipped) 件）",
            "打鍵\t回数 \(samples.count)\t打鍵列の長さの合計 \(keyCount)",
            ["読みの文字数", "打鍵数", "中央値ms", "90%ms", "99%ms", "最大ms"].joined(separator: "\t"),
        ]
        func row(_ label: String, _ group: [KeystrokeBench.Sample]) -> String {
            let s = LatencyStats(group.map(\.seconds))
            let ms = { (x: Double) in String(format: "%.1f", x * 1000) }
            return [label, String(s.count), ms(s.median), ms(s.p90), ms(s.p99), ms(s.max)].joined(separator: "\t")
        }
        lines.append(row("全体", samples))
        let width = Self.kanaBucketWidth
        let buckets = Dictionary(grouping: samples) { $0.kanaCount / width }
        for bucket in buckets.keys.sorted() {
            lines.append(row("\(bucket * width)〜\(bucket * width + width - 1)", buckets[bucket]!))
        }
        return lines
    }

    /// 文ごとに 打鍵列 \t 最後の liveText。`tugime-cli --live` の出力と同じ形なので diff できる
    public var finalTextLines: [String] {
        finalTexts.map { "\($0.keys)\t\($0.liveText)" }
    }
}

/// プロセスの最大常駐量（バイト）
func maxResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}
