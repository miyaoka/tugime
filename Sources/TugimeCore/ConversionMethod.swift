import Foundation

/// 日本語区間を変換する方式。入力メソッドも CLI も検証の道具も、変換器はこの値からだけ作る。
/// 検証で測った方式と入力メソッドが使う方式が別の組み立てにならないことが、この型の役目である。
///
/// 方式を足すときは case を 1 つ足し、`make()` と `specs` の表に 1 行ずつ足す。
/// 検証の道具は case を switch しないので、触らずに新しい方式を測れる
public enum ConversionMethod: Sendable, Hashable {
    /// azooKey の辞書と n-gram だけで変換する。検証の基準
    case azooKey
    /// 採点は azooKey、表示は azooKey の Zenzai に GGUF のモデルを渡して選び直す
    case azooKeyZenzai(weight: URL)

    /// 基準の方式。検証はどの対象の方式にも、これの出力を並べて残す
    public static let baseline = ConversionMethod.azooKey

    /// 方式が読むモデルのファイル。nil ならモデルを使わない方式。
    /// モデルを使う方式の出力が基準と全件で一致したら、モデルが効いていないとみなす
    public var weight: URL? {
        switch self {
        case .azooKey: nil
        case .azooKeyZenzai(let weight): weight
        }
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case missingFile(String)
        public var description: String {
            switch self {
            case .unknown(let spec): "変換の方式が分からない: \(spec)。azookey か zenzai:<GGUF のパス> を渡す"
            case .missingFile(let path): "モデルのファイルが無い: \(path)"
            }
        }
    }

    /// 指定の接頭辞から方式を作る表。パスを取らない方式は接頭辞と完全一致させる
    private static let specs: [(prefix: String, make: @Sendable (URL?) -> ConversionMethod?)] = [
        ("azookey", { $0 == nil ? .azooKey : nil }),
        ("zenzai:", { $0.map { .azooKeyZenzai(weight: $0) } }),
    ]

    /// `azookey` / `zenzai:<GGUF のパス>` を読む。相対パスは今の作業ディレクトリから引く。
    /// モデルのファイルが無ければ止める（変換エンジンは読めないモデルを黙って無視するので、ここで先に止める）
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
        case .azooKey: "azookey"
        case .azooKeyZenzai(let weight): "zenzai:\(weight.path)"
        }
    }

    /// 変換器を作り、モデルを読み込み終えた状態で返す。最初の変換で読み込みの時間が混ざらないよう、ここで先読みまで済ませる。
    /// モデルを読めなければ止まる
    public func make() -> any JapaneseConverting {
        switch self {
        case .azooKey:
            return AzooKeyConverter(zenzaiWeight: nil)
        case .azooKeyZenzai(let weight):
            let converter = AzooKeyConverter(zenzaiWeight: weight)
            converter.preloadZenzai()
            return converter
        }
    }
}
