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
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    /// 候補の窓の 1 行目から 9 行目を選ぶ数字キー
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
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
    /// Space で変換した文節。nil なら読みを表示している
    private var clauses: [Clause]?
    /// 候補を選ぶ対象の文節
    private var focus = 0
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

    // MARK: 候補の窓

    override func candidates(_ sender: Any!) -> [Any]! {
        guard let clauses else { return [] }
        return clauses[focus].candidates
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        select(candidateString?.string)
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        select(candidateString?.string)
        candidatePanel.hide()
    }

    private func select(_ text: String?) {
        guard let text, var clauses, let index = clauses[focus].candidates.firstIndex(of: text) else { return }
        clauses[focus].selected = index
        self.clauses = clauses
        if let client = client() {
            showMarkedText(client)
        }
    }

    private func showCandidatePanel() {
        candidatePanel.update()
        candidatePanel.show(kIMKLocateCandidatesBelowHint)
        highlightSelectedCandidate()
    }

    private func highlightSelectedCandidate() {
        guard let clauses else { return }
        let id = candidatePanel.candidateStringIdentifier(clauses[focus].output)
        candidatePanel.selectCandidate(withIdentifier: id)
    }

    // MARK: キー入力

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
        if clauses != nil {
            return handleConverted(event, client: client)
        }
        return handleComposing(event, client: client)
    }

    /// 読みを表示している間
    private func handleComposing(_ event: NSEvent, client: IMKTextInput) -> Bool {
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter:
            guard !keys.isEmpty else { return false }
            commit(client)
            return true
        case KeyCode.space:
            guard !keys.isEmpty else { return false }
            clauses = sharedSegmenter.clauses(keys)
            focus = 0
            showMarkedText(client)
            return true
        case KeyCode.backspace:
            guard !keys.isEmpty else { return false }
            keys.removeLast()
            showMarkedText(client)
            return true
        case KeyCode.escape:
            guard !keys.isEmpty else { return false }
            keys = ""
            showMarkedText(client)
            return true
        default:
            return appendCharacter(event, client: client)
        }
    }

    /// Space で変換した後
    private func handleConverted(_ event: NSEvent, client: IMKTextInput) -> Bool {
        let panelVisible = candidatePanel.isVisible()
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter:
            commit(client)
        case KeyCode.space, KeyCode.down:
            if panelVisible {
                moveCandidate(by: 1, client: client)
            } else {
                showCandidatePanel()
            }
        case KeyCode.up:
            if panelVisible {
                moveCandidate(by: -1, client: client)
            }
        case KeyCode.left, KeyCode.right:
            let count = clauses?.count ?? 1
            focus = min(max(focus + (event.keyCode == KeyCode.left ? -1 : 1), 0), count - 1)
            candidatePanel.hide()
            showMarkedText(client)
        case KeyCode.escape, KeyCode.backspace:
            // 候補の窓を閉じる。窓が無ければ変換をやめて読みに戻る
            if panelVisible {
                candidatePanel.hide()
            } else {
                clauses = nil
                showMarkedText(client)
            }
        default:
            if panelVisible, let line = KeyCode.digits.firstIndex(of: event.keyCode) {
                pickLine(line)
                return true
            }
            commit(client)
            return appendCharacter(event, client: client)
        }
        return true
    }

    private func moveCandidate(by delta: Int, client: IMKTextInput) {
        guard var clauses else { return }
        let count = clauses[focus].candidates.count
        clauses[focus].selected = (clauses[focus].selected + delta + count) % count
        self.clauses = clauses
        highlightSelectedCandidate()
        showMarkedText(client)
    }

    private func pickLine(_ line: Int) {
        let id = candidatePanel.candidateIdentifier(atLineNumber: line)
        guard id != NSNotFound else { return }
        candidatePanel.selectCandidate(withIdentifier: id)
        select(candidatePanel.selectedCandidateString()?.string)
        candidatePanel.hide()
    }

    /// 印字できる ASCII を打鍵列に足す。それ以外のキーは確定してからアプリに渡す
    private func appendCharacter(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard let text = event.characters, text.count == 1, let scalar = text.unicodeScalars.first,
              (0x21...0x7E).contains(scalar.value)
        else {
            commit(client)
            return false
        }
        keys.append(text)
        showMarkedText(client)
        return true
    }

    // MARK: 表示と確定

    /// 変換前は、日本語区間をかな、英語区間を打ったままで表示する。変換後は文節ごとの選択を表示し、選ぶ対象の文節に太い下線を引く
    private func showMarkedText(_ client: IMKTextInput) {
        let marked = NSMutableAttributedString()
        var focusStart = 0
        if let clauses {
            for (index, clause) in clauses.enumerated() {
                if index == focus { focusStart = marked.length }
                marked.append(NSAttributedString(string: clause.output, attributes: [
                    .underlineStyle: (index == focus ? NSUnderlineStyle.thick : NSUnderlineStyle.single).rawValue,
                    .markedClauseSegment: index,
                ]))
            }
        } else {
            let reading = sharedSegmenter.segment(keys).map(\.reading).joined()
            marked.append(NSAttributedString(string: reading, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]))
            focusStart = marked.length
        }
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: focusStart, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// 未確定の文字列を確定する。変換していなければ、区切りを選んだ結果を確定する
    private func commit(_ client: IMKTextInput) {
        candidatePanel.hide()
        guard !keys.isEmpty else { return }
        let text = (clauses ?? sharedSegmenter.clauses(keys)).map(\.output).joined()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        keys = ""
        clauses = nil
        focus = 0
    }
}
