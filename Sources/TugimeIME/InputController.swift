import Carbon
import Cocoa
import InputMethodKit
import TugimeCore

/// 日本語モードと英数モードの入力源 ID は、バンドル ID に接尾辞を付けたもの
enum InputMode: String {
    case japanese = "Japanese"
    case roman = "Roman"

    var sourceID: String { "\(Bundle.main.bundleIdentifier!).\(rawValue)" }

    init(sourceID: String) {
        self = sourceID.hasSuffix(".\(InputMode.roman.rawValue)") ? .roman : .japanese
    }
}

private enum KeyCode {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let space: UInt16 = 49
    static let backspace: UInt16 = 51
    static let escape: UInt16 = 53
    static let eisu: UInt16 = 102
    static let kana: UInt16 = 104
}

/// 変換器はプロセスに 1 つだけ持つ。辞書と語表の読み込みが重いので、入力源ごとに作らない
let sharedSegmenter: Segmenter = {
    do {
        return try Segmenter(table: .bundled(), english: .bundled(), japanese: AzooKeyConverter())
    } catch {
        fatalError("tugime を初期化できない: \(error)")
    }
}()

@objc(TugimeInputController)
final class TugimeInputController: IMKInputController {
    /// 未確定の打鍵列
    private var keys = ""
    /// Space で変換した結果。nil なら読みを表示している
    private var converted: String?
    private var mode: InputMode = .japanese

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard let id = value as? String else { return }
        let next = InputMode(sourceID: id)
        if next == .roman, let client = sender as? IMKTextInput {
            commit(client)
        }
        mode = next
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        commit(client)
    }

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? IMKTextInput {
            commit(client)
        }
        super.deactivateServer(sender)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else { return false }
        // パスワード欄などで安全入力が有効なら、何も変換せずアプリに渡す
        if IsSecureEventInputEnabled() {
            commit(client)
            return false
        }
        switch event.keyCode {
        case KeyCode.eisu:
            commit(client)
            client.selectMode(InputMode.roman.sourceID)
            return true
        case KeyCode.kana:
            client.selectMode(InputMode.japanese.sourceID)
            return true
        default:
            break
        }
        if mode == .roman { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if !modifiers.isEmpty {
            commit(client)
            return false
        }
        return handleJapanese(event, client: client)
    }

    private func handleJapanese(_ event: NSEvent, client: IMKTextInput) -> Bool {
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter:
            guard !keys.isEmpty else { return false }
            commit(client)
            return true
        case KeyCode.space:
            guard !keys.isEmpty else { return false }
            converted = sharedSegmenter.segment(keys).map(\.output).joined()
            showMarkedText(client)
            return true
        case KeyCode.backspace:
            guard !keys.isEmpty else { return false }
            if converted != nil {
                converted = nil
            } else {
                keys.removeLast()
            }
            showMarkedText(client)
            return true
        case KeyCode.escape:
            guard !keys.isEmpty else { return false }
            if converted != nil {
                converted = nil
            } else {
                keys = ""
            }
            showMarkedText(client)
            return true
        default:
            break
        }
        guard let text = event.characters, text.count == 1, let scalar = text.unicodeScalars.first,
              (0x21...0x7E).contains(scalar.value)
        else {
            // 矢印キーなどは確定してからアプリに渡す
            commit(client)
            return false
        }
        if converted != nil {
            commit(client)
        }
        keys.append(text)
        showMarkedText(client)
        return true
    }

    /// 日本語区間はかな、英語区間は打ったままの読みを表示する。変換後は変換結果を表示する
    private func showMarkedText(_ client: IMKTextInput) {
        let text = converted ?? sharedSegmenter.segment(keys).map(\.reading).joined()
        let attributed = NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// 未確定の文字列を確定する。変換していなければ変換結果を確定する
    private func commit(_ client: IMKTextInput) {
        guard !keys.isEmpty else { return }
        let text = converted ?? sharedSegmenter.segment(keys).map(\.output).joined()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        keys = ""
        converted = nil
    }
}
