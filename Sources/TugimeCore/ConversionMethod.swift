import Foundation

/// 日本語区間を変換する方式。入力メソッドも CLI も検証の道具も、変換器はこの値からだけ作る。
/// 検証で測った方式と入力メソッドが使う方式が別の組み立てにならないことが、この型の役目である。
///
/// 方式を足すときは case を 1 つ足し、接頭辞の定数と `specs` の表に 1 行ずつ足す。switch の網羅はコンパイラが確かめ、表との往復はテストが確かめる。
/// 検証の道具は case を switch せず、使い方の文言も `forms` から作るので、触らずに新しい方式を測れる
public enum ConversionMethod: Sendable, Hashable {
    /// azooKey の辞書と n-gram だけで変換する。検証の基準
    case azooKey
    /// 採点は azooKey、表示は azooKey の Zenzai に GGUF のモデルを渡して選び直す
    case azooKeyZenzai(weight: URL)
    /// 採点と候補の窓は azooKey（Zenzai なし）、表示は tugime が zenz 形式の GGUF のモデルを直接動かした出力そのもの
    case direct(weight: URL)

    /// 基準の方式。検証はどの対象の方式にも、これの出力を並べて残す
    public static let baseline = ConversionMethod.azooKey

    /// 方式が読むモデルのファイル。nil ならモデルを使わない方式。
    /// モデルを使う方式の出力が基準と全件で一致したら、モデルが効いていないとみなす
    public var weight: URL? {
        switch self {
        case .azooKey: nil
        case .azooKeyZenzai(let weight): weight
        case .direct(let weight): weight
        }
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case missingFile(String)
        public var description: String {
            switch self {
            case .unknown(let spec): "変換の方式が分からない: \(spec)。\(ConversionMethod.forms) のどれかを渡す"
            case .missingFile(let path): "モデルのファイルが無い: \(path)"
            }
        }
    }

    /// 指定の接頭辞。読む表と記録に残す名前の両方が使う
    private static let azooKeyPrefix = "azookey"
    private static let zenzaiPrefix = "zenzai:"
    private static let directPrefix = "direct:"

    /// 指定の接頭辞から方式を作る表。form は使い方に出す書式。パスを取らない方式は接頭辞と完全一致させる
    private static let specs: [(prefix: String, form: String, make: @Sendable (URL?) -> ConversionMethod?)] = [
        (azooKeyPrefix, azooKeyPrefix, { $0 == nil ? .azooKey : nil }),
        (zenzaiPrefix, "\(zenzaiPrefix)<GGUF のパス>", { $0.map { .azooKeyZenzai(weight: $0) } }),
        (directPrefix, "\(directPrefix)<GGUF のパス>", { $0.map { .direct(weight: $0) } }),
    ]

    /// 指定できる書式の一覧。CLI の使い方とエラーの文言はこれを使う
    public static let forms = specs.map(\.form).joined(separator: " | ")

    /// `forms` のどれかを読む。相対パスは今の作業ディレクトリから引く。
    /// モデルのファイルが無ければ、辞書を読み込む前にここで止める。在っても読めないモデルは make() の先読みで止まる
    public init(spec: String) throws {
        for entry in Self.specs where spec.hasPrefix(entry.prefix) {
            let rest = String(spec.dropFirst(entry.prefix.count))
            let weight = rest.isEmpty ? nil : URL(fileURLWithPath: rest).standardizedFileURL
            guard let method = entry.make(weight) else { continue }
            if let weight, !FileManager.default.fileExists(atPath: weight.path) {
                throw ParseError.missingFile(weight.path)
            }
            self = method
            return
        }
        throw ParseError.unknown(spec)
    }

    /// 記録に残す名前。`init(spec:)` と往復する
    public var spec: String {
        switch self {
        case .azooKey: Self.azooKeyPrefix
        case .azooKeyZenzai(let weight): Self.zenzaiPrefix + weight.path
        case .direct(let weight): Self.directPrefix + weight.path
        }
    }

    /// 同梱の綴りの表と語表で、この方式の区切りを作る。入力メソッド・CLI・打鍵の計測は、区切りをこれからだけ作る
    public func makeSegmenter() throws -> Segmenter {
        try Segmenter(table: .bundled(), english: .bundled(), japanese: make())
    }

    /// 変換器を作り、モデルを読み込み終えた状態で返す。最初の変換で読み込みの時間が混ざらないよう、ここで先読みまで済ませる。
    /// モデルを読めなければプロセスごと止まる（fatalError。投げるエラーではないので、呼び出し元は受け止められない）
    public func make() -> any JapaneseConverting {
        switch self {
        case .azooKey:
            return AzooKeyConverter(zenzaiWeight: nil)
        case .azooKeyZenzai(let weight):
            let converter = AzooKeyConverter(zenzaiWeight: weight)
            converter.preloadZenzai()
            return converter
        case .direct(let weight):
            // azooKey には Zenzai を渡さない。llama.cpp にモデルを載せるのは ZenzGenerator だけになる
            return DirectConverter(scorer: AzooKeyConverter(zenzaiWeight: nil), generator: ZenzGenerator(weight: weight))
        }
    }
}
