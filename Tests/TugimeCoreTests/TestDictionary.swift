import Foundation
@testable import TugimeCore

/// テストが読むシステム辞書。bun scripts/fetch-dictionary.ts がリポジトリの直下に組み立てたもの。読むだけなので全テストで共有する
enum TestDictionary {
    static let shared: SystemDictionary = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        do { return try SystemDictionary(url: SystemDictionary.inRepository(root)) } catch { fatalError("\(error)") }
    }()
}
