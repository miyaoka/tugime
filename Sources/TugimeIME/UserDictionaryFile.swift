import Cocoa
import TugimeCore
import UniformTypeIdentifiers

/// 入力メソッドが読む利用者の辞書のファイルと、最後に読んだときの状態。
/// 置き場所は Application Support で、Sandbox の中（~/Library/Containers/<bundle id>/Data/Library/Application Support）になるので、
/// entitlements を足さずに読める。開発版と配布版は bundle id が違うので、別のファイルを読む
final class UserDictionaryFile {
    let url: URL
    /// 最後に見たファイルの更新時刻。ファイルが無ければ内側が nil、まだ見ていなければ外側が nil
    private var seen: Date??
    /// ファイルを読めなかった理由。読めた辞書に替えるか、ファイルを消すまで残る。残っている間も、前に読めた辞書で変換を続ける
    private(set) var rejection: String?

    init(url: URL) {
        self.url = url
    }

    static func inputMethod() -> UserDictionaryFile {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("tugime を初期化できない: Application Support の場所が分からない")
        }
        return UserDictionaryFile(url: support.appendingPathComponent("tugime/dictionary.tsv"))
    }

    /// ファイルが無いときに作る中身。書式と例をコメントの行に書く
    static let template = """
        # tugime の辞書。1 行 1 語で、打鍵、タブ、表記の順に書く。# で始まる行は読まない
        # 打鍵は日本語モードで打つとおりの綴り。保存すると、次に打ち始めたときから効く
        # 3 つ目に ja か en を書くと、打鍵の区間を日本語区間か英語区間にする。書かなければ、表記が ASCII だけなら en、それ以外は ja
        # mannzu\t萬子
        # github\tGitHub
        # sake\t鮭\tja

        """

    /// ファイルを、プレーンテキストの既定のアプリで開く。無ければ template で作ってから開く。
    /// 拡張子の .tsv に結び付いた表計算のアプリではなく、テキストとして編集させる。
    /// 開けなければ failed をメインスレッドで呼ぶ。アプリを起こす失敗は後から届くので、作る失敗と同じ受け口にまとめる
    func openInEditor(failed: @escaping @MainActor (any Error) -> Void) {
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: url.path) {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.template.write(to: url, atomically: true, encoding: .utf8)
            }
            guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "プレーンテキストを開くアプリが無い"])
            }
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                Task { @MainActor in failed(error) }
            }
        } catch {
            failed(error)
        }
    }

    /// 更新時刻が前に見たときと違えば読み直し、読めたら segmenter の利用者の語を置き換える。ファイルが無いのは語が無い状態で、誤りではない。
    /// 置き換えると未確定の文字列が終わるので、未確定の文字列の外でだけ呼ぶ
    func refresh(into segmenter: Segmenter) {
        let modified: Date?
        do {
            modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch CocoaError.fileReadNoSuchFile {
            modified = nil
        } catch {
            // 次に更新時刻を読めたときは、前と同じ時刻でも読み直して、理由を決め直す
            seen = nil
            rejection = "tugime の辞書の更新時刻を読めない: \(error.localizedDescription)"
            return
        }
        guard seen != .some(modified) else { return }
        // 中身で決まる誤り（書式の誤りと、変換エンジンが扱えない読みの文字）は同じ中身なら何度読んでも同じなので、時刻を覚えて読み直さない。
        // それ以外の失敗（ファイルの読み込み、文字の表、組み立ての書き出し）は一時のこともあるので、時刻を覚えず、次の打ち始めにまた読む
        do {
            let dictionary = try modified.map { _ in try UserDictionary(contents: String(contentsOf: url, encoding: .utf8)) } ?? .empty
            try segmenter.replaceUserDictionary(dictionary)
            seen = modified
            rejection = nil
        } catch let error as UserDictionary.ParseError {
            seen = modified
            rejection = error.description
        } catch let error as UserDictionary.ImportError {
            if case .unsupportedCharacter = error { seen = modified } else { seen = nil }
            rejection = error.description
        } catch {
            seen = nil
            rejection = "tugime の辞書を読めない: \(error.localizedDescription)"
        }
    }
}
