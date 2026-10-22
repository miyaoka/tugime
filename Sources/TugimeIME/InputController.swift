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
    /// 未確定の文字列全体を 1 つの文字種にするキー
    static let wholeConversions: [UInt16: WholeConversion] = [
        97: .hiragana,
        98: .katakana,
        100: .halfwidthKatakana,
        101: .fullwidthRoman,
        109: .roman,
    ]
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
    /// 打ち始めたときにカーソルの前にあったもの。文の途中なら、最初の日本語区間を前の語に続く形で評価する
    private var leading: JapaneseContext = .start
    /// この文字の後ろから打ち始めたら文頭として扱う
    private static let sentenceEnds: Set<Character> = ["\n", "\r", "。", "！", "？", ".", "!", "?"]

    /// 入力欄のカーソルの直前の 1 文字を読む。読めない、文頭、文末の後なら文頭として扱う
    private static func leadingContext(of client: IMKTextInput) -> JapaneseContext {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0,
              let before = client.attributedSubstring(from: NSRange(location: selection.location - 1, length: 1))?.string.last,
              !sentenceEnds.contains(before), !before.isWhitespace
        else { return .start }
        return .afterEnglish
    }

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

    /// マウスで候補を選んだとき。自分で窓を動かしている間の通知は反映済みなので無視する
    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        guard !movingPanel else { return }
        select(candidateString?.string)
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard !movingPanel else { return }
        select(candidateString?.string)
        candidatePanel.hide()
    }

    private func select(_ text: String?) {
        guard let text, var clauses, let index = clauses[focus].candidates.firstIndex(of: text) else { return }
        clauses[focus].selected = index
        self.clauses = clauses
        panelIndex = index
        if let client = client() {
            showMarkedText(client)
        }
    }

    /// 窓が強調している候補の番号。IMKCandidates の selectCandidate(withIdentifier:) と selectedCandidate() は
    /// 選択を動かせず値も当てにならない（macOS 10.13 以降の既知の不具合）ので、位置はこちらで持つ
    private var panelIndex = 0
    private var movingPanel = false

    private func showCandidatePanel() {
        guard let clauses else { return }
        candidatePanel.update()
        candidatePanel.show(kIMKLocateCandidatesBelowHint)
        // 窓は作り直すと先頭を強調するので、選んでいる候補まで送る
        panelIndex = 0
        movePanel(to: clauses[focus].selected)
    }

    /// 矢印キーと同じ moveDown: / moveUp: を窓に送り、強調を index まで動かす
    private func movePanel(to index: Int) {
        movingPanel = true
        defer { movingPanel = false }
        let step = index > panelIndex ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:))
        for _ in 0..<abs(index - panelIndex) {
            candidatePanel.perform(step, with: nil)
        }
        panelIndex = index
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
        if !keys.isEmpty, let kind = KeyCode.wholeConversions[event.keyCode] {
            convertWhole(to: kind, client: client)
            return true
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
            clauses = sharedSegmenter.clauses(keys, leading: leading)
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
        movePanel(to: clauses[focus].selected)
        showMarkedText(client)
    }

    /// 未確定の文字列全体を 1 つの文節にして、指定の文字種で表示する。Enter で確定する
    private func convertWhole(to kind: WholeConversion, client: IMKTextInput) {
        let text = sharedSegmenter.convertWhole(keys, to: kind)
        clauses = [Clause(kind: .english, source: keys, candidates: [text], selected: 0)]
        focus = 0
        candidatePanel.hide()
        showMarkedText(client)
    }

    /// 印字できる ASCII を打鍵列に足す。それ以外のキーは確定してからアプリに渡す
    private func appendCharacter(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard let text = event.characters, text.count == 1, let scalar = text.unicodeScalars.first,
              (0x21...0x7E).contains(scalar.value)
        else {
            commit(client)
            return false
        }
        if keys.isEmpty {
            leading = Self.leadingContext(of: client)
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
            let reading = sharedSegmenter.segment(keys, leading: leading).map(\.reading).joined()
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
        let text = (clauses ?? sharedSegmenter.clauses(keys, leading: leading)).map(\.output).joined()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        keys = ""
        clauses = nil
        focus = 0
    }
}
