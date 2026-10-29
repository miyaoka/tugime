import Foundation
import TugimeCore

/// 打鍵の性能を測る 1 文。読みを利用者の綴りの表で逆にたどった打鍵列と、打鍵ごとの打ち終えた読みの文字数を持つ
public struct KeystrokeScript: Sendable {
    /// 入力欄でこの文の前に何を置くか
    public enum Context: Sendable, CaseIterable {
        /// 問題の left。空の問題もある
        case problem
        /// 問題の left の前に別の文をつないだ入力欄から、入力メソッドと同じく上限の長さまで読んだもの
        case full
    }

    public var id: String
    public var context: Context
    /// 打ち始めに入力欄のカーソルより前にあるもの
    public var leading: Segmenter.Leading
    public var reading: String
    /// 打ち終えたときの許容解。途中の画面の判定に使う
    public var answers: [String]
    public var spelled: [SpelledKana]
    /// spelled の keys を繋いだもの
    public var keys: String

    init(id: String, context: Context, field: String, reading: String, answers: [String], spelled: [SpelledKana]) {
        self.id = id
        self.context = context
        leading = Segmenter.Leading(field: field)
        self.reading = reading
        self.answers = answers
        self.spelled = spelled
        keys = spelled.map(\.keys).joined()
    }

    /// 選んだ文と、綴りで書けない文字（全角の括弧など）を含むので外した問題
    public struct Selection: Sendable {
        public var scripts: [KeystrokeScript]
        public var skipped: [Problem]
    }

    /// AJIMEE-Bench の問題を、問題ファイルの順に全部使う。left は入力欄のカーソルより前の文字列として、入力メソッドと同じく読んで渡す。
    /// まず各問題を問題の left で打ち、続けて同じ問題を left の前に全問題の left をつないで上限の長さにした文字列で打つ（id の末尾に @full）。
    /// 綴りで書けない文字を含む問題は外して返す。外した数は呼び出し元が出す
    public static func select(from problems: [Problem], table: RomajiTable) -> Selection {
        var selection = Selection(scripts: [], skipped: [])
        let ajimee = problems.filter { $0.set == AJIMEE.set }
        let filler = ajimee.map(\.left).joined()
        var full: [KeystrokeScript] = []
        for problem in ajimee {
            guard case .oneOf(let answers) = problem.check else { preconditionFailure("AJIMEE-Bench の問題 \(problem.id) の判定が許容解でない") }
            guard let spelled = Segmenter.spelling(of: problem.kana, table: table) else {
                selection.skipped.append(problem)
                continue
            }
            selection.scripts.append(KeystrokeScript(id: problem.id, context: .problem, field: problem.left, reading: problem.kana, answers: answers, spelled: spelled))
            full.append(KeystrokeScript(id: problem.id + "@full", context: .full, field: filler + problem.left, reading: problem.kana, answers: answers, spelled: spelled))
        }
        selection.scripts += full
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
/// ピークのメモリはプロセスの最大常駐量で測るので、同じプロセスで別の方式（基準も含む）の変換器を作らない
public enum KeystrokeBench {
    public struct Sample: Sendable {
        public var scriptID: String
        /// 何打鍵目か（1 始まり）
        public var keystroke: Int
        public var kanaCount: Int
        /// 文の前の文字列の置き方と、それが空でないか
        public var context: KeystrokeScript.Context
        public var hasLeft: Bool
        public var seconds: Double
    }

    /// 問題の文脈で打った文の 1 打鍵の画面と、その判定
    public struct Live: Sendable {
        public var typed: String
        /// 確定した文字列と未確定の表示をつないだもの
        public var display: String
        /// 文の最後の打鍵か。最後の打鍵の画面は打ち終えた結果なので、途中の画面の集計に入れない。
        /// 打ち終えた表示を許容解と照らすのは精度の物差し（tugime-eval accuracy）で、前の部分を確定しない
        /// （確定しながら打った最後の画面とは違うことがある）
        public var isLast: Bool
        public var check: LiveCheck
    }

    public struct Report: Sendable {
        public var method: String
        /// ConversionMethod.make(dictionary:) と区切りの準備にかかった時間。モデルの先読みを含む。システム辞書は mmap で開いてから渡すので、引いたページを読む時間は打鍵の側に入る
        public var loadSeconds: Double
        /// 読み込み直後と、全打鍵の後の最大常駐量（getrusage の ru_maxrss、macOS はバイト）
        public var peakBytesAfterLoad: Int
        public var peakBytes: Int
        public var skipped: Int
        public var samples: [Sample]
        /// 問題の left で打った文の、打鍵ごとの画面。同じ確定の設定の `tugime-cli --stable <設定> --before <left> --typing <打鍵列>` の画面と一致するはずのもの。
        /// 上限の長さの文脈で打った文は時間を測るためのもので、含めない
        public var lives: [Live]
        /// 問題の left で打った文の数
        public var scriptCount: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        /// 測る文が 1 つも無い。時間の分布を作れないので、変換器を作る前に止める
        case noScripts(skipped: Int)
        public var description: String {
            switch self {
            case .noScripts(let skipped): "測る文が無い（綴りで書けず外した文 \(skipped) 件）"
            }
        }
    }

    /// 不変条件:
    /// - 文ごとに、入力メソッドと同じく LiveTyping で 1 打鍵ずつ足し、表示の前の部分が変わらなくなったら確定する。
    ///   1 打鍵の時間は確定を含み、判定は確定した文字列と未確定の表示をつないだ画面に対して行う
    /// - 文の前に endComposition を呼ぶ。文の中では呼ばない（入力メソッドは打ち終えるまで覚えを持ち越す）
    public static func run(
        selection: KeystrokeScript.Selection,
        method: ConversionMethod,
        dictionary: SystemDictionary,
        table: RomajiTable,
        stable: StablePrefix,
        watchdog: Watchdog,
        progress: (String) -> Void
    ) throws -> Report {
        guard !selection.scripts.isEmpty else { throw Failure.noScripts(skipped: selection.skipped.count) }
        let clock = ContinuousClock()
        let loadStart = clock.now
        watchdog.armLoad("読み込み \(method.spec)")
        let segmenter = try method.makeSegmenter(dictionary: dictionary)
        let loadSeconds = seconds(clock.now - loadStart)
        let peakAfterLoad = maxResidentBytes()
        progress("変換器の読み込み \(String(format: "%.2f", loadSeconds))s、文 \(selection.scripts.count) 件（綴りで書けず外した文 \(selection.skipped.count) 件）")

        var samples: [Sample] = []
        var lives: [Live] = []
        for (n, script) in selection.scripts.enumerated() {
            segmenter.endComposition()
            let keys = Array(script.keys)
            let kanaCounts = script.kanaCounts
            var slowest = 0.0
            var typing = LiveTyping(leading: script.leading, stable: stable)
            for i in 1...keys.count {
                watchdog.arm(item: "\(script.id) の \(i) 打鍵目")
                let step = typing.type(keys[i - 1], segmenter: segmenter)
                let typed = step.typed
                let elapsed = step.seconds
                let display = step.screen
                slowest = max(slowest, elapsed)
                samples.append(Sample(scriptID: script.id, keystroke: i, kanaCount: kanaCounts[i - 1], context: script.context, hasLeft: !script.leading.text.isEmpty, seconds: elapsed))
                if script.context == .problem {
                    let check = LiveCheck.judge(display: display, typed: typed, answers: script.answers, reading: script.reading, table: table)
                    lives.append(Live(typed: typed, display: display, isLast: i == keys.count, check: check))
                }
            }
            progress("[\(n + 1)/\(selection.scripts.count)] \(script.id) \(keys.count) 打鍵 最大 \(String(format: "%.1f", slowest * 1000))ms")
        }
        segmenter.endComposition()
        return Report(
            method: method.spec, loadSeconds: loadSeconds, peakBytesAfterLoad: peakAfterLoad, peakBytes: maxResidentBytes(),
            skipped: selection.skipped.count, samples: samples, lives: lives,
            scriptCount: selection.scripts.filter { $0.context == .problem }.count
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

    /// 先頭に 方式・読み込み秒・最大常駐量・文と打鍵の数。続いて列の名前と、全体の行、文脈の有無ごとの行、読みの文字数の区切りごとの行。
    /// 列: 区切り 打鍵数 中央値 90% 99% 最大（ms）
    public var lines: [String] {
        let mib = { (bytes: Int) in String(format: "%.1fMiB", Double(bytes) / 1_048_576) }
        var lines = [
            "方式\t\(method)",
            "読み込み\t\(String(format: "%.2f", loadSeconds))s",
            "最大常駐量\t読み込み直後 \(mib(peakBytesAfterLoad))\t全打鍵の後 \(mib(peakBytes))",
            "文\t\(scriptCount) 件 × 文脈 \(KeystrokeScript.Context.allCases.count) 通り（外した文 \(skipped) 件）",
            "打鍵\t\(samples.count) 回",
        ]
        func row(_ label: String, _ group: [KeystrokeBench.Sample]) -> String {
            let s = LatencyStats(group.map(\.seconds))
            let ms = { (x: Double) in String(format: "%.1f", x * 1000) }
            return [label, String(s.count), ms(s.median), ms(s.p90), ms(s.p99), ms(s.max)].joined(separator: "\t")
        }
        let midway = lives.filter { !$0.isLast }
        lines.append((["途中の画面", "打鍵数"] + LiveCheck.allCases.map(\.rawValue)).joined(separator: "\t"))
        lines.append((["全体", String(midway.count)] + LiveCheck.allCases.map { check in String(midway.filter { $0.check == check }.count) }).joined(separator: "\t"))
        lines.append(["読みの文字数", "打鍵数", "中央値ms", "90%ms", "99%ms", "最大ms"].joined(separator: "\t"))
        lines.append(row("全体", samples))
        let groups: [(label: String, matches: (KeystrokeBench.Sample) -> Bool)] = [
            ("文脈なし", { $0.context == .problem && !$0.hasLeft }),
            ("問題の文脈", { $0.context == .problem && $0.hasLeft }),
            ("文脈\(Segmenter.Leading.maxLength)字", { $0.context == .full }),
        ]
        for group in groups {
            let matched = samples.filter(group.matches)
            if !matched.isEmpty { lines.append(row(group.label, matched)) }
        }
        let width = Self.kanaBucketWidth
        let buckets = Dictionary(grouping: samples) { $0.kanaCount / width }
        for bucket in buckets.keys.sorted() {
            lines.append(row("\(bucket * width)〜\(bucket * width + width - 1)", buckets[bucket]!))
        }
        return lines
    }

    /// 打鍵ごとに 打鍵列 \t 画面 \t 判定。方式や版の間で diff して、途中の画面が変わった打鍵を見る
    public var liveLines: [String] {
        lives.map { "\($0.typed)\t\($0.display)\t\($0.check.rawValue)" }
    }
}

/// プロセスの最大常駐量（バイト）
func maxResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}
