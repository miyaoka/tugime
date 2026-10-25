import Foundation
import TugimeCore

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

    /// 更新時刻が前に見たときと違えば読み直し、読めたら segmenter の利用者の語を置き換える。ファイルが無いのは語が無い状態で、誤りではない。
    /// 置き換えると未確定の文字列が終わるので、未確定の文字列の外でだけ呼ぶ
    func refresh(into segmenter: Segmenter) {
        let modified: Date?
        do {
            modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch CocoaError.fileReadNoSuchFile {
            modified = nil
        } catch {
            rejection = "利用者の辞書の更新時刻を読めない: \(error.localizedDescription)"
            return
        }
        guard seen != .some(modified) else { return }
        seen = modified
        guard modified != nil else {
            segmenter.replaceUserDictionary(.empty)
            rejection = nil
            return
        }
        do {
            segmenter.replaceUserDictionary(try UserDictionary(contents: String(contentsOf: url, encoding: .utf8)))
            rejection = nil
        } catch let error as UserDictionary.ParseError {
            rejection = error.description
        } catch {
            rejection = "利用者の辞書を読めない: \(error.localizedDescription)"
        }
    }
}
