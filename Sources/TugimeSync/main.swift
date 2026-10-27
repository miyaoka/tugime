import Darwin
import Foundation
import UserDictionaryLayout
import os

// 配布版の辞書を開発版の辞書へ写す道具。開発版の .app に同梱し、開発版の設定の窓から起動する。
// 開発版の IME は Sandbox の中で動き、配布版のコンテナを読めないので、写すのはこの道具が Sandbox の外で行う。
// 乗っ取られた IME から届く入力にならないよう、引数を受け取らず、辞書の中身を解釈せずにバイト列のまま写し、画面を出さない。
// 確認と結果は起動した IME が出す。失敗の理由はログ（カテゴリ sync）に書き、終了コードを 1 にする

/// 写す元と先のコンテナの bundle id。組み立てのときに Info.plist に書く
guard let info = Bundle.main.infoDictionary,
    let source = info["TugimeDictionarySource"] as? String, let target = info["TugimeDictionaryTarget"] as? String,
    let subsystem = Bundle.main.bundleIdentifier
else {
    fatalError("Info.plist に CFBundleIdentifier・TugimeDictionarySource・TugimeDictionaryTarget のどれかが無い")
}
let logger = Logger(subsystem: subsystem, category: "sync")

/// 置き換えの途中の一時ファイルの名前
let temporaryName = ".\(UserDictionaryLayout.fileName).sync"

struct SyncError: Error, CustomStringConvertible {
    let description: String

    /// 直前の呼び出しの errno を添える
    static func errno(_ what: String) -> SyncError {
        SyncError(description: "\(what): \(String(cString: strerror(Darwin.errno)))")
    }
}

/// パスのどの要素の symlink もたどらずに開く。コンテナの中は持ち主の Sandbox の中のプロセスが作れるので、
/// Sandbox の外のこの道具が symlink をたどると、コンテナの外のファイルを読み書きさせられる
func openNoFollow(_ path: String, _ flags: Int32) throws -> Int32 {
    let fd = open(path, flags | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard fd >= 0 else { throw SyncError.errno("開けない \(path)") }
    return fd
}

func directory(of bundleID: String) -> String {
    UserDictionaryLayout.applicationSupport(ofContainer: bundleID).appendingPathComponent(UserDictionaryLayout.directory).path
}

/// 写す先のディレクトリの中で、一時ファイルに書いてから置き換える。ディレクトリは作らない（開発版の IME が自分のコンテナに作る）
func replace(in directory: Int32, with data: Data) throws {
    // 前に止まったときの一時ファイルが残っていれば消す。symlink なら link そのものを消す
    _ = unlinkat(directory, temporaryName, 0)
    let fd = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw SyncError.errno("一時ファイルを作れない") }
    do {
        try FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(contentsOf: data)
        // 置き換えると更新時刻が変わり、IME は次に打ち始めたときに読み直す
        guard renameatx_np(directory, temporaryName, directory, UserDictionaryLayout.fileName, UInt32(RENAME_NOFOLLOW_ANY)) == 0 else {
            throw SyncError.errno("置き換えられない")
        }
    } catch {
        _ = unlinkat(directory, temporaryName, 0)
        throw error
    }
}

/// 読む元を、ハードリンクが 1 本の通常のファイルのときだけ読む。コンテナの外のファイルへのハードリンクは写さない。
/// FIFO で止まらないよう O_NONBLOCK で開き、通常のファイルかを確かめてから読む
func readRegularFile(_ path: String) throws -> Data {
    let fd = try openNoFollow(path, O_RDONLY | O_UNIQUE | O_NONBLOCK)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var status = stat()
    guard fstat(fd, &status) == 0 else { throw SyncError.errno("調べられない \(path)") }
    guard status.st_mode & S_IFMT == S_IFREG else { throw SyncError(description: "通常のファイルではない \(path)") }
    return try handle.readToEnd() ?? Data()
}

do {
    let data = try readRegularFile("\(directory(of: source))/\(UserDictionaryLayout.fileName)")
    let to = try openNoFollow(directory(of: target), O_RDONLY | O_DIRECTORY)
    defer { close(to) }
    try replace(in: to, with: data)
} catch {
    logger.error("配布版の辞書を写せない: \(String(describing: error), privacy: .public)")
    exit(1)
}
