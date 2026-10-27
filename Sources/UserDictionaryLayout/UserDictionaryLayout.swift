import Foundation

/// 利用者の辞書の置き場所。読む TugimeIME と、配布版の辞書を開発版へ写す TugimeSync が共有する
public enum UserDictionaryLayout {
    /// Application Support の中の、辞書を置くディレクトリ
    public static let directory = "tugime"
    public static let fileName = "dictionary.tsv"

    /// Sandbox の外から見た、bundle id のコンテナの Application Support。Sandbox の中から見た Application Support と同じ場所
    public static func applicationSupport(ofContainer bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support")
    }
}
