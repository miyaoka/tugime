import Carbon
import Cocoa
import InputMethodKit
import TugimeCore

/// バンドルを入力源として登録する。有効化はしない（利用者がシステム設定の「+」で追加する）
func register() -> Int32 {
    let url = Bundle.main.bundleURL as CFURL
    let status = TISRegisterInputSource(url)
    print("TISRegisterInputSource \(Bundle.main.bundleURL.path) -> \(status)")
    return status == noErr ? 0 : 1
}

/// このバンドルの入力源を、未有効のものも含めて TIS から列挙する
func printStatus() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        print("バンドル ID が無い")
        return 1
    }
    let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
        print("入力源 0 件")
        return 1
    }
    func property(_ source: TISInputSource, _ key: CFString) -> Any? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }
    print("入力源 \(list.count) 件")
    for source in list {
        let id = property(source, kTISPropertyInputSourceID) as? String ?? "?"
        let category = property(source, kTISPropertyInputSourceCategory) as? String ?? "?"
        let type = property(source, kTISPropertyInputSourceType) as? String ?? "?"
        let enabled = (property(source, kTISPropertyInputSourceIsEnabled) as? Bool).map { "\($0)" } ?? "?"
        let selectable = (property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool).map { "\($0)" } ?? "?"
        let ascii = (property(source, kTISPropertyInputSourceIsASCIICapable) as? Bool).map { "\($0)" } ?? "?"
        print("\(id)\tcategory=\(category)\ttype=\(type)\tenabled=\(enabled)\tselectCapable=\(selectable)\tasciiCapable=\(ascii)")
    }
    return 0
}

/// 組み立てたバンドルから綴りの表・語表・辞書・表示の変換のモデルを読み、1 文を表示の変換で変換して出す。読めなければ初期化の時点で止まる。
/// 続けて、利用者の辞書を組み立てる文字の表もバンドルから読めるかを、1 語の辞書で変換して確かめる。利用者の辞書のファイルは読まない
func check() -> Int32 {
    let input = "kyouhagoogledekensaku"
    print("\(input)\t\(sharedSegmenter.liveText(input))")
    let word = (keys: "i-sou", entry: "いーそう\t一索", text: "一索")
    do {
        try sharedSegmenter.replaceUserDictionary(UserDictionary(contents: word.entry))
    } catch {
        print("利用者の辞書を入れられない: \(error)")
        return 1
    }
    let shown = sharedSegmenter.liveText(word.keys)
    print("\(word.keys)\t\(shown)")
    return shown == word.text ? 0 : 1
}

switch CommandLine.arguments.dropFirst().first {
case "--register":
    exit(register())
case "--status":
    exit(printStatus())
case "--check":
    exit(check())
default:
    break
}

guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String else {
    fatalError("Info.plist に InputMethodConnectionName が無い")
}
// IMKServer はプロセスに 1 つだけ作る。2 つあると Chromium 系のアプリに入力が届かない
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
// 候補の窓もプロセスに 1 つ。窓を出している間も、キーはまず入力コントローラが受け取る
let candidatePanel: IMKCandidates = {
    let panel = IMKCandidates(server: server, panelType: kIMKSingleColumnScrollingCandidatePanel)!
    panel.setAttributes([IMKCandidatesSendServerKeyEventFirst: true])
    return panel
}()
// 未確定の文字列の下に出す知らせの窓もプロセスに 1 つ
let compositionNotice = CompositionNotice()
// 綴りの表・語表・辞書と表示の変換のモデルの読み込みを、最初の打鍵より前に済ませる。利用者の辞書も読んでおく
userDictionaryFile.refresh(into: sharedSegmenter)
NSApplication.shared.run()
