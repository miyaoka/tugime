import Carbon
import Cocoa
import InputMethodKit
import TugimeCore
import TugimeEngine

/// Carbon の仮想キーコード。NSEvent.keyCode と同じ UInt16 にそろえる
private enum KeyCode {
    static let returnKey = UInt16(kVK_Return)
    static let enter = UInt16(kVK_ANSI_KeypadEnter)
    static let space = UInt16(kVK_Space)
    static let backspace = UInt16(kVK_Delete)
    static let escape = UInt16(kVK_Escape)
    static let eisu = UInt16(kVK_JIS_Eisu)
    static let kana = UInt16(kVK_JIS_Kana)
    static let left = UInt16(kVK_LeftArrow)
    static let right = UInt16(kVK_RightArrow)
    static let down = UInt16(kVK_DownArrow)
    static let up = UInt16(kVK_UpArrow)
    /// 選んでいる文節か未確定の文字列全体を、1 つの文字種にするキー
    static let characterForms: [UInt16: CharacterForm] = [
        UInt16(kVK_F6): .hiragana,
        UInt16(kVK_F7): .katakana,
        UInt16(kVK_F8): .halfwidthKatakana,
        UInt16(kVK_F9): .fullwidthRoman,
        UInt16(kVK_F10): .roman,
    ]
    /// Ctrl と押すと矢印キーとして扱うキー。英字の文字ではなくキーの位置で決める
    static let arrowAliases: [UInt16: (keyCode: UInt16, character: Int)] = [
        UInt16(kVK_ANSI_H): (left, NSLeftArrowFunctionKey),
        UInt16(kVK_ANSI_J): (down, NSDownArrowFunctionKey),
        UInt16(kVK_ANSI_K): (up, NSUpArrowFunctionKey),
        UInt16(kVK_ANSI_L): (right, NSRightArrowFunctionKey),
    ]
}

/// 区切りと変換はプロセスに 1 つだけ持つ。辞書・語表・モデルの読み込みが重いので、入力欄のコントローラごとに作らない
let conversion: ConversionQueue = {
    // 表示の変換のモデルはバンドルの Contents/Resources/model に、システム辞書は Contents/Resources/dictionary に同梱する
    guard let resources = Bundle.main.resourceURL else { fatalError("tugime を初期化できない: バンドルの Contents/Resources が無い") }
    let method = ConversionMethod.inputMethod(modelDirectory: resources.appendingPathComponent("model"))
    guard let model = method.weight, FileManager.default.fileExists(atPath: model.path) else {
        fatalError("tugime を初期化できない: 表示の変換のモデルが Contents/Resources/model に無い")
    }
    do {
        let dictionary = try SystemDictionary(url: resources.appendingPathComponent(SystemDictionary.directory).appendingPathComponent(SystemDictionary.fileName))
        return ConversionQueue(segmenter: try method.makeSegmenter(dictionary: dictionary))
    } catch {
        fatalError("tugime を初期化できない: \(error)")
    }
}()

/// 利用者の辞書のファイル。区切りと同じくプロセスに 1 つ
let userDictionaryFile = UserDictionaryFile.inputMethod()

@objc(TugimeInputController)
final class TugimeInputController: IMKInputController {
    /// 未確定の打鍵列
    private var keys = ""
    /// 文節の選択に入った後の文節（Shift+Space・矢印キー・F6〜F10 で入る）。nil なら打っている途中の変換を表示している
    private var clauses: [Clause]?
    /// 候補を選ぶ対象の文節
    private var focus = 0
    /// 打ち始めたときにカーソルの前にあったもの
    private var leading: Segmenter.Leading = .start
    /// 入力欄が前の文字列を返さないときの代わりに、tugime が確定した文字列を持つ
    private var leadingContext = LeadingContext()

    // 打っている途中の変換は、打鍵を待たせないよう変換のキューに積み、届いたら表示を差し替える
    /// 打っている途中の変換の世代。未確定の文字列を終えるか作り直すたびに進め、届いた変換が今のものかを見分ける
    private var conversionGeneration = 0
    /// 変換が届いた打鍵列と表示。後から打った分をつなぐ土台にする
    private var converted: [(keys: String, display: Segmenter.LiveDisplay)] = []
    /// 変換をキューに積み、まだ届いていない。積むのは 1 つずつで、届いたときに最新の打鍵列を積む
    private var converting = false
    /// 打っている途中に出している文字列。Enter はこれを確定する
    private var shownText = ""

    /// 入力欄のカーソルより前の文字列を読む。入力欄が返さなければ、tugime が続けて確定した文字列を使う
    private func readLeading(of client: IMKTextInput) -> Segmenter.Leading {
        leadingContext.leading(field: Self.fieldLeading(of: client))
    }

    /// 入力欄のカーソルより前の文字列を読む。カーソルの位置が分からなければ前に何も無いとする
    private static func fieldLeading(of client: IMKTextInput) -> Segmenter.Leading {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else { return .start }
        return Segmenter.Leading(caret: selection.location) { client.attributedSubstring(from: $0)?.string }
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

    nonisolated override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        nonisolated(unsafe) let target = client
        onMain { commit(target) }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let client = sender as? IMKTextInput
        onMain {
            if let client { commit(client) }
            leadingContext.forgetCommits()
        }
        super.deactivateServer(sender)
    }

    /// 入力メニュー（メニューバーの入力ソースのメニュー）に足す項目。選ぶと IMK がこのコントローラの action を呼ぶ
    nonisolated override func menu() -> NSMenu! {
        nonisolated(unsafe) var menu: NSMenu?
        MainActor.assumeIsolated {
            let built = NSMenu()
            // 設定は窓に集める。よく使うものは入口としてここにも並べる
            built.addItem(NSMenuItem(title: "tugime の辞書を編集…", action: #selector(openUserDictionary(_:)), keyEquivalent: ""))
            built.addItem(NSMenuItem(title: "設定…", action: #selector(openSettings(_:)), keyEquivalent: ""))
            menu = built
        }
        return menu
    }

    @objc nonisolated func openUserDictionary(_ sender: Any?) {
        onMain { userDictionaryFile.openInEditor() }
    }

    @objc nonisolated func openSettings(_ sender: Any?) {
        onMain { settingsWindow.show() }
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else { return false }
        nonisolated(unsafe) let keyEvent = event
        nonisolated(unsafe) let target = client
        return onMain {
            let handled = handleKeyDown(keyEvent, client: target)
            // アプリに渡したキーは入力欄を変えうる
            if !handled { leadingContext.forgetCommits() }
            return handled
        }
    }

    // MARK: 候補の窓

    /// 選んでいる文節の候補を選んでいる最中なら、見えている範囲と選んでいる候補。窓が画面に出ているか（アプリが位置を返したか）によらない
    private var candidatePage: CandidatePage?

    /// 候補を選び始め、窓を選んでいる文節の下に置く。窓を置くのはここだけで、候補を進めても置き直さない
    private func openCandidates(_ clauses: [Clause], client: IMKTextInput) {
        let candidatePage = CandidatePage(count: clauses[focus].candidates.count, selected: clauses[focus].selected)
        self.candidatePage = candidatePage
        candidateWindow.onClick = { [weak self] index in self?.clickCandidate(index) }
        // 選んでいる文節の最初の文字の、未確定の文字列の中での位置。showMarkedText と同じく UTF-16 で数える
        let start = clauses[..<focus].reduce(0) { $0 + ($1.output as NSString).length }
        candidateWindow.show(clauses[focus].candidates, page: candidatePage, below: client, characterIndex: start)
    }

    private func closeCandidates() {
        candidatePage = nil
        candidateWindow.hide()
    }

    /// 窓の行をクリックしたとき。その候補を選んで窓を閉じる
    private func clickCandidate(_ index: Int) {
        guard let clauses, let client = client() else { return }
        self.clauses = Clause.selecting(index, at: focus, in: clauses)
        closeCandidates()
        showMarkedText(client)
    }

    /// 窓に出ている番号の数字キー。その候補を選んでから → を押したときと同じく、窓を閉じて次の文節を選ぶ。
    /// 窓に出ていない番号なら何もしない
    private func selectCandidate(numbered number: Int, clauses: [Clause], client: IMKTextInput) {
        guard let index = candidatePage?.index(forNumber: number) else { return }
        self.clauses = Clause.selecting(index, at: focus, in: clauses)
        focus = Clause.focus(focus, movedBy: 1, in: clauses)
        closeCandidates()
        showMarkedText(client)
    }

    // MARK: キー入力

    private func handleKeyDown(_ event: NSEvent, client: IMKTextInput) -> Bool {
        // 英数・かなキーでの入力ソースの切り替えは OS が行う。アプリに渡すと空白を入れるアプリがあるので受け取る
        switch event.keyCode {
        case KeyCode.eisu:
            commit(client)
            return true
        case KeyCode.kana:
            return true
        default:
            break
        }
        if !keys.isEmpty, let arrow = arrowEvent(aliasedBy: event) {
            return handleKeyDown(arrow, client: client)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if !modifiers.isEmpty {
            commit(client)
            return false
        }
        if !keys.isEmpty, let form = KeyCode.characterForms[event.keyCode] {
            // 文節が 2 つ以上ある間は選んでいる文節だけを変える。打っている途中と文節が 1 つのときは未確定の文字列全体を変える
            if let clauses, clauses.count > 1 {
                convertFocusedClause(to: form, clauses: clauses, client: client)
            } else {
                convertWhole(to: form, client: client)
            }
            return true
        }
        if let clauses {
            return handleConverted(event, clauses: clauses, client: client)
        }
        return handleComposing(event, client: client)
    }

    /// Ctrl+H/J/K/L を、Ctrl を外した ← ↓ ↑ → に作り直す。Shift は残すので Ctrl+Shift+H/L は Shift+← → になる
    private func arrowEvent(aliasedBy event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers == .control, let alias = KeyCode.arrowAliases[event.keyCode] else { return nil }
        let character = String(Character(UnicodeScalar(UInt16(alias.character))!))
        return NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.control).union([.function, .numericPad]),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: event.isARepeat,
            keyCode: alias.keyCode
        )
    }

    /// 打っている途中（文節の選択に入る前）。
    /// 打っている途中は、選んでいる文節が無い。文節に分けて選ぶ文節を決めるのは、文節の選択に入るときが初めて。
    /// カーソルを末尾に置くのはターミナルへの対処で（`showMarkedText`）、選んでいる文節を表さない。
    /// 向きを持つ ← → は、選んでいる文節が無いところから 1 つ進んだ文節を選ぶ。→ は 0 番目の最初の文節、← は -1 番目で、端から回って最後の文節。
    /// どちらも空白だけの文節は飛ばす（`Clause.focus`）。打鍵列は空白で始まらないので、最初の文節は空白だけにならない。
    /// Shift+← → は、同じ向きで選んだ文節を伸縮する。向きを持たないキー（Shift+Space・↑ ↓・Shift+Enter）は、最初の文節を選ぶ
    private func handleComposing(_ event: NSEvent, client: IMKTextInput) -> Bool {
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter:
            guard !keys.isEmpty else { return false }
            if event.modifierFlags.contains(.shift) {
                // 矢印キーと同じく文節の選択に入り、最初の文節までを確定する
                let clauses = segmentedClauses()
                self.clauses = clauses
                focus = 0
                commitThroughFocus(clauses, client: client)
            } else {
                commit(client)
            }
            return true
        case KeyCode.space:
            guard !keys.isEmpty else { return false }
            // 打っている途中も変換して見せているので、Space は日本語の文に英語の語句を空白で区切って混ぜるのに使い、
            // 文節の選択には Shift+Space で入る
            if !event.modifierFlags.contains(.shift) {
                // 空白の後の Space は、空白の前の語を反対の言語にして、その文節の候補の窓を出す。次の Space で元の言語の表記に進む。
                // 反対の言語にできない語なら、空白を足す
                let (keys, leading) = (keys, leading)
                if keys.last == " ", let flipped = conversion.sync({ $0.clausesFlippingLastWord(keys, leading: leading) }) {
                    clauses = flipped.clauses
                    focus = flipped.focus
                    showMarkedText(client)
                    openCandidates(flipped.clauses, client: client)
                    return true
                }
                self.keys.append(" ")
                showMarkedText(client)
                return true
            }
            // 打っている途中に変換はもう見せているので、↓ と同じく最初の文節を選んで候補の窓まで出す
            let clauses = segmentedClauses()
            self.clauses = clauses
            focus = 0
            showMarkedText(client)
            return handleConverted(event, clauses: clauses, client: client)
        case KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down:
            // 打っている途中も変換して見せているので、矢印キーで Shift+Space を押さずに文節の選択に入る
            guard !keys.isEmpty else { return false }
            let clauses = segmentedClauses()
            self.clauses = clauses
            focus = event.keyCode == KeyCode.left ? Clause.focus(0, movedBy: -1, in: clauses) : 0
            // ↑ ↓ は文節の表示を描き直さないので、先に文節の選択の表示にしておく
            showMarkedText(client)
            // Shift 無しの ← → は、文節を選ぶところまでがそのキーの動き
            let selectsOnly = [KeyCode.left, KeyCode.right].contains(event.keyCode) && !event.modifierFlags.contains(.shift)
            if selectsOnly { return true }
            return handleConverted(event, clauses: clauses, client: client)
        case KeyCode.backspace:
            guard !keys.isEmpty else { return false }
            // 見えている最後の 1 文字をその打鍵ごと消し、残りは変換し直さずに見えていたまま残す。表示を残せなければ、打ったかなの最後の単位を消して変換し直す
            let deleted = Segmenter.deletingLast(of: keys, shown: liveDisplay, leading: leading, table: conversion.table)
            keys = deleted.keys
            if !keys.isEmpty, let display = deleted.display { keep(display) }
            if keys.isEmpty { endComposition() }
            showMarkedText(client)
            return true
        case KeyCode.escape:
            guard !keys.isEmpty else { return false }
            keys = ""
            endComposition()
            showMarkedText(client)
            return true
        default:
            return appendCharacter(event, client: client)
        }
    }

    /// 文節の選択に入った後
    private func handleConverted(_ event: NSEvent, clauses: [Clause], client: IMKTextInput) -> Bool {
        let choosingCandidate = candidatePage != nil
        if choosingCandidate, let number = event.characters.flatMap(Int.init), (1...CandidatePage.rows).contains(number) {
            selectCandidate(numbered: number, clauses: clauses, client: client)
            return true
        }
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter:
            if event.modifierFlags.contains(.shift) {
                commitThroughFocus(clauses, client: client)
            } else {
                commit(client)
            }
        case KeyCode.space, KeyCode.down:
            if choosingCandidate {
                moveCandidate(by: 1, clauses: clauses, client: client)
            } else {
                openCandidates(clauses, client: client)
            }
        case KeyCode.up:
            if choosingCandidate {
                moveCandidate(by: -1, clauses: clauses, client: client)
            }
        case KeyCode.left, KeyCode.right:
            let step = event.keyCode == KeyCode.left ? -1 : 1
            if event.modifierFlags.contains(.shift) {
                let (focus, leading) = (focus, leading)
                self.clauses = conversion.sync { $0.resize(clauses, at: focus, by: step, leading: leading) }
            } else {
                focus = Clause.focus(focus, movedBy: step, in: clauses)
            }
            closeCandidates()
            showMarkedText(client)
        case KeyCode.escape, KeyCode.backspace:
            // 候補の窓を閉じる。窓が無ければ文節の選択をやめて、打っている途中の表示に戻る
            if choosingCandidate {
                closeCandidates()
            } else {
                self.clauses = nil
                showMarkedText(client)
            }
        default:
            commit(client)
            return appendCharacter(event, client: client)
        }
        return true
    }

    private func moveCandidate(by delta: Int, clauses: [Clause], client: IMKTextInput) {
        let count = clauses[focus].candidates.count
        let index = (clauses[focus].selected + delta + count) % count
        self.clauses = Clause.selecting(index, at: focus, in: clauses)
        candidatePage?.select(index)
        if let candidatePage { candidateWindow.redraw(candidatePage) }
        showMarkedText(client)
    }

    /// 未確定の文字列全体を 1 つの文節にして、指定の文字種で表示する。Enter で確定する
    private func convertWhole(to form: CharacterForm, client: IMKTextInput) {
        let (keys, leading) = (keys, leading)
        clauses = [conversion.sync { $0.wholeClause(keys, to: form, leading: leading) }]
        focus = 0
        closeCandidates()
        showMarkedText(client)
    }

    /// 選んでいる文節を指定の文字種にする。その文字列を文節の候補として選ぶので、候補の窓で選び直せる。
    /// 文節の境目が 1 つの綴りの途中にあって英字にできないときは、Shift+Enter と同じく何もしない
    private func convertFocusedClause(to form: CharacterForm, clauses: [Clause], client: IMKTextInput) {
        let focus = focus
        guard let text = conversion.sync({ $0.convertClause(clauses, at: focus, to: form) }) else { return }
        self.clauses = Clause.selecting(text: text, at: focus, in: clauses)
        closeCandidates()
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
            leading = readLeading(of: client)
            // 辞書を替えるのは未確定の文字列の始まりだけにする。打っている途中に替えると、同じ打鍵列の表示が途中で変わる
            userDictionaryFile.refresh(into: conversion)
        }
        keys.append(text)
        showMarkedText(client)
        return true
    }

    // MARK: 表示と確定

    /// 文節の選択に入る前は打っている途中の変換を 1 つの未確定の文字列として表示し、それが打った読みと合わなければ警告の窓を出す。
    /// 入った後は文節ごとの選択を表示し、選んでいる文節を強調する。警告の窓は出さない
    private func showMarkedText(_ client: IMKTextInput) {
        let marked = NSMutableAttributedString()
        var differs = false
        if let clauses {
            for (index, clause) in clauses.enumerated() {
                let style = index == focus ? kTSMHiliteSelectedConvertedText : kTSMHiliteConvertedText
                marked.append(styled(clause.output, style: style, at: marked.length))
            }
        } else {
            let live = liveDisplay
            shownText = live.text
            marked.append(styled(live.text, style: kTSMHiliteRawText, at: 0))
            differs = live.differsFromInput
        }
        // カーソルは常に末尾に置く。ターミナル（xterm.js）はカーソルの位置を未確定の文字列の終わりとして読むので、途中に置くと確定する文字列が欠ける
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: marked.length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        if differs {
            rewriteWarning.show(below: client)
        } else {
            rewriteWarning.hide()
        }
        if clauses == nil { requestConversion() }
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

    /// 打っている途中に表示する文字列と、それが打った読みと合わない変換を含むか
    private var liveDisplay: Segmenter.LiveDisplay {
        Segmenter.liveDisplay(of: keys, converted: converted, leading: leading, table: conversion.table)
    }

    /// 今の打鍵列の変換を、届いていなければキューに積む。積んでいる変換があれば、それが届いてから積む
    private func requestConversion() {
        guard !converting, clauses == nil, !keys.isEmpty, !converted.contains(where: { $0.keys == self.keys }) else { return }
        converting = true
        let (keys, leading, generation) = (keys, leading, conversionGeneration)
        conversion.async { segmenter in
            let display = segmenter.liveDisplay(keys, leading: leading)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.didConvert(display, keys: keys, generation: generation) }
            }
        }
    }

    /// 変換が届いた。今の未確定の文字列のものなら覚えて表示を差し替え、その間に打たれていれば最新の打鍵列を積む。
    /// 変換の途中に Backspace でその打鍵列に戻って表示を残していれば、残した表示を使い、届いた変換は捨てる
    private func didConvert(_ display: Segmenter.LiveDisplay, keys converted: String, generation: Int) {
        converting = false
        if generation == conversionGeneration, !self.converted.contains(where: { $0.keys == converted }) {
            self.converted.append((converted, display))
            if clauses == nil, !keys.isEmpty, let client = client() {
                showMarkedText(client)
                return
            }
        }
        requestConversion()
    }

    /// Backspace で残した表示を、今の打鍵列の表示としてすぐ見せ、変換にも覚えさせる（文節の選択に入っても同じ表記にするため）。
    /// 変換が覚えた表示に差し替え、覚えられなければ今の打鍵列を変換し直す
    private func keep(_ display: Segmenter.LiveDisplay) {
        converted.append((keys, display))
        let (keys, leading, generation) = (keys, leading, conversionGeneration)
        conversion.async { segmenter in
            let kept = segmenter.keepDisplay(display.text, for: keys, leading: leading)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.didKeep(kept, keys: keys, generation: generation) }
            }
        }
    }

    private func didKeep(_ kept: Segmenter.LiveDisplay?, keys keptKeys: String, generation: Int) {
        guard generation == conversionGeneration else { return }
        converted.removeAll { $0.keys == keptKeys }
        if let kept { converted.append((keptKeys, kept)) }
        if clauses == nil, keys == keptKeys, let client = client() { showMarkedText(client) }
    }

    /// 届いた変換を捨て、次に届く変換を今の打鍵列のものとして扱う
    private func forgetConversions() {
        conversionGeneration += 1
        converted = []
        shownText = ""
    }

    /// 未確定の文字列を終える。区切りと変換が覚えたものも捨てる
    private func endComposition() {
        forgetConversions()
        conversion.async { $0.endComposition() }
    }

    /// 打鍵列を文節に分ける。積んでいる変換が終わるのを待つ
    private func segmentedClauses() -> [Clause] {
        let (keys, leading) = (keys, leading)
        return conversion.sync { $0.clauses(keys, leading: leading) }
    }

    /// 選んでいる文節までを確定し、残りの文節は変換したまま、次の文節を選んだ状態で残す。
    /// 選んでいるのが最後の文節なら全体を確定する。切る位置に当たる打鍵が決まらなければ何もしない
    private func commitThroughFocus(_ clauses: [Clause], client: IMKTextInput) {
        // 後ろが空白だけなら、空白ごと全体を確定する（`Segmenter.commit(_:through:)` は空白だけを残さない）
        guard clauses[(focus + 1)...].contains(where: { !$0.isSpace }) else {
            commit(client)
            return
        }
        let focus = focus
        guard let result = conversion.sync({ $0.commit(clauses, through: focus) }) else {
            // 確定しないときも、文節の選択に入った表示にそろえる。打っている途中から入ったときはまだ描いていない
            showMarkedText(client)
            return
        }
        closeCandidates()
        insert(result.text, client: client)
        keys = result.keys
        self.clauses = result.rest
        self.focus = 0
        forgetConversions()
        // 残りを打っている途中の表示に戻したときは、確定した文字列の後ろとして区切る
        leading = readLeading(of: client)
        showMarkedText(client)
    }

    /// 未確定の文字列を、表示しているとおりに確定する
    private func commit(_ client: IMKTextInput) {
        closeCandidates()
        rewriteWarning.hide()
        guard !keys.isEmpty else { return }
        insert(clauses?.map(\.output).joined() ?? shownText, client: client)
        keys = ""
        clauses = nil
        focus = 0
        endComposition()
    }

    private func insert(_ text: String, client: IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        leadingContext.didCommit(text)
    }
}
