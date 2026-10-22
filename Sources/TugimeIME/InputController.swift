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
    /// Space で変換した文節。nil なら打っている途中の変換を表示している
    private var clauses: [Clause]?
    /// 候補を選ぶ対象の文節
    private var focus = 0
    private var mode: InputMode = .japanese
    /// 打ち始めたときにカーソルの前にあったもの
    private var leading: Segmenter.Leading = .start

    /// 入力欄のカーソルの直前の 1 文字を読む。読めない、空白・改行、文末の記号の後なら文頭とする。
    /// それ以外の ASCII（英字・数字・記号）の後は英語の後とする。日本語モードが出す文字は全角なので、ASCII があればそこは英語の文脈になる
    private static func leadingContext(of client: IMKTextInput) -> Segmenter.Leading {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0,
              let before = client.attributedSubstring(from: NSRange(location: selection.location - 1, length: 1))?.string.last,
              !before.isWhitespace,
              !before.unicodeScalars.contains(where: \.properties.isSentenceTerminal)
        else { return .start }
        return before.isASCII ? .afterEnglish : .afterJapanese
    }

    // MARK: InputMethodKit からの呼び出し
    // InputMethodKit の基底クラスは隔離の指定を持たないので、上書きする関数は nonisolated にし、中身を onMain でメインアクターとして動かす。
    // IMK から渡される引数は並行性で安全と示されていない型だが、同期的に使うだけなので nonisolated(unsafe) で受け直して渡す

    /// メインアクターで同期実行する。IMK の呼び出しはメインスレッドで届く前提で、崩れたらここで止める
    private nonisolated func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
        MainActor.assumeIsolated(work)
    }

    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    nonisolated override init() {
        super.init()
    }

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    nonisolated override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard let id = value as? String else { return }
        nonisolated(unsafe) let client = sender as? IMKTextInput
        onMain { switchMode(to: InputMode(sourceID: id), client: client) }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        nonisolated(unsafe) let target = client
        onMain { commit(target) }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        if let client = sender as? IMKTextInput {
            nonisolated(unsafe) let target = client
            onMain { commit(target) }
        }
        super.deactivateServer(sender)
    }

    nonisolated override func candidates(_ sender: Any!) -> [Any]! {
        onMain { currentCandidates }
    }

    /// マウスで候補を選んだとき。自分で窓を動かしている間の通知は反映済みなので無視する
    nonisolated override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        let text = candidateString?.string
        onMain {
            guard !movingPanel else { return }
            select(text)
        }
    }

    nonisolated override func candidateSelected(_ candidateString: NSAttributedString!) {
        let text = candidateString?.string
        onMain {
            guard !movingPanel else { return }
            select(text)
            candidatePanel.hide()
        }
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else { return false }
        nonisolated(unsafe) let keyEvent = event
        nonisolated(unsafe) let target = client
        return onMain { handleKeyDown(keyEvent, client: target) }
    }

    // MARK: 状態

    private func switchMode(to next: InputMode, client: IMKTextInput?) {
        if next == .roman, let client {
            commit(client)
        }
        mode = next
    }

    // MARK: 候補の窓

    private var currentCandidates: [String] {
        guard let clauses else { return [] }
        return clauses[focus].candidates
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

    private func handleKeyDown(_ event: NSEvent, client: IMKTextInput) -> Bool {
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

    /// Space を押す前
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
        case KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down:
            // 打っている途中も変換して見せているので、矢印キーで Space を押さずに文節の選択に入る。
            // Space と同じく最初の文節を選び、選んだ後の操作としてそのキーを扱う
            guard !keys.isEmpty else { return false }
            clauses = sharedSegmenter.clauses(keys, leading: leading)
            focus = 0
            return handleConverted(event, client: client)
        case KeyCode.backspace:
            guard !keys.isEmpty else { return false }
            keys.removeLast()
            if keys.isEmpty { sharedSegmenter.endComposition() }
            showMarkedText(client)
            return true
        case KeyCode.escape:
            guard !keys.isEmpty else { return false }
            keys = ""
            sharedSegmenter.endComposition()
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
            // Shift 付きで選ぶ文節を移し、Shift 無しで選んでいる文節を伸縮する
            let step = event.keyCode == KeyCode.left ? -1 : 1
            if event.modifierFlags.contains(.shift) {
                focus = min(max(focus + step, 0), (clauses?.count ?? 1) - 1)
            } else if let clauses {
                self.clauses = sharedSegmenter.resize(clauses, at: focus, by: step)
            }
            candidatePanel.hide()
            showMarkedText(client)
        case KeyCode.escape, KeyCode.backspace:
            // 候補の窓を閉じる。窓が無ければ文節の選択をやめて、打っている途中の表示に戻る
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
        let text = sharedSegmenter.convertWhole(keys, to: kind, leading: leading)
        let span = ClauseSpan(index: 0, source: keys, reading: keys, context: .start)
        clauses = [Clause(kind: .english, reading: keys, candidates: [text], selected: 0, span: span)]
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

    /// Space の前は打っている途中の変換を 1 つの未確定の文字列として表示する。Space の後は文節ごとの選択を表示し、選んでいる文節を強調する
    private func showMarkedText(_ client: IMKTextInput) {
        let marked = NSMutableAttributedString()
        if let clauses {
            for (index, clause) in clauses.enumerated() {
                let style = index == focus ? kTSMHiliteSelectedConvertedText : kTSMHiliteConvertedText
                marked.append(styled(clause.output, style: style, at: marked.length))
            }
        } else {
            marked.append(styled(liveText, style: kTSMHiliteRawText, at: 0))
        }
        // カーソルは常に末尾に置く。ターミナル（xterm.js）はカーソルの位置を未確定の文字列の終わりとして読むので、途中に置くと確定する文字列が欠ける
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: marked.length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// 下線の種類と太さはクライアントが決めるので、文節の状態だけを IMK に渡して属性を受け取る
    private func styled(_ text: String, style: Int, at location: Int) -> NSAttributedString {
        let range = NSRange(location: location, length: (text as NSString).length)
        let raw = mark(forStyle: style, at: range) ?? [:]
        let attributes = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            (key as? String).map { (NSAttributedString.Key($0), value) }
        })
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Space を押す前に表示する文字列
    private var liveText: String {
        sharedSegmenter.liveText(keys, leading: leading)
    }

    /// 未確定の文字列を、表示しているとおりに確定する
    private func commit(_ client: IMKTextInput) {
        candidatePanel.hide()
        guard !keys.isEmpty else { return }
        let text = clauses?.map(\.output).joined() ?? liveText
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        keys = ""
        clauses = nil
        focus = 0
        sharedSegmenter.endComposition()
    }
}
