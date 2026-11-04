import Cocoa
import InputMethodKit
import TugimeCore

/// 選んでいる文節の候補を、未確定の文字列の下に出す窓。見えている行に番号を振り、選んでいる候補を強調する。
/// どの候補を選んでいるかは呼び出し側が `CandidatePage` で持ち、窓はそれを描くだけ
final class CandidateWindow {
    private var panel: NSPanel?
    private let list = CandidateListView()

    /// 行をクリックしたとき、その候補の位置で呼ぶ
    var onClick: ((Int) -> Void)? {
        get { list.onClick }
        set { list.onClick = newValue }
    }

    /// candidates を page のとおりに、未確定の文字列の characterIndex 文字目（選んでいる文節の最初の文字）の下に描く。
    /// アプリが位置を返さないときは出さない
    func show(_ candidates: [String], page: CandidatePage, below client: IMKTextInput, characterIndex: Int) {
        list.candidates = candidates
        list.page = page
        list.needsDisplay = true
        let panel = panel ?? PanelPlacement.makePanel()
        panel.contentView = list
        self.panel = panel
        PanelPlacement.show(panel, size: list.fittingSize, below: client, characterIndex: characterIndex)
    }

    /// 窓を置き直さずに、選んでいる候補と見えている範囲だけを描き直す。窓の幅は全候補で決まるので変わらない
    func redraw(_ page: CandidatePage) {
        list.page = page
        list.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

/// 見えている範囲の候補を、番号・候補の順に 1 行ずつ描く。候補が 1 画面に収まらなければ、最後に「選んでいる位置/候補の数」を描く
private final class CandidateListView: NSView {
    private static let padding: CGFloat = 4
    private static let rowHeight: CGFloat = 24
    private static let numberWidth: CGFloat = 22
    /// 候補の文字列の後ろの余白
    private static let trailing: CGFloat = 12
    private static let minimumTextWidth: CGFloat = 80
    private static let font = NSFont.systemFont(ofSize: 15)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    var candidates: [String] = []
    var page: CandidatePage?
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    /// アプリが前面のまま、最初のクリックで候補を選べるようにする
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var showsPosition: Bool { (page?.count ?? 0) > CandidatePage.rows }

    /// 幅は全候補のうち最も長いものに合わせ、スクロールしても窓の幅を変えない
    override var fittingSize: NSSize {
        let textWidth = candidates.map { ($0 as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
        let rows = page?.visible.count ?? 0
        let width = Self.padding * 2 + Self.numberWidth + max(textWidth, Self.minimumTextWidth) + Self.trailing
        let height = Self.padding * 2 + CGFloat(rows + (showsPosition ? 1 : 0)) * Self.rowHeight
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let page else { return }
        for (row, (number, index)) in page.numbered.enumerated() {
            let rect = NSRect(x: Self.padding, y: Self.padding + CGFloat(row) * Self.rowHeight, width: bounds.width - Self.padding * 2, height: Self.rowHeight)
            let selected = index == page.selected
            if selected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
            let secondary: NSColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            drawText("\(number)", font: Self.numberFont, color: secondary, x: rect.minX + 6, in: rect)
            drawText(candidates[index], font: Self.font, color: primary, x: rect.minX + Self.numberWidth, in: rect)
        }
        guard showsPosition else { return }
        let rect = NSRect(x: Self.padding, y: Self.padding + CGFloat(page.visible.count) * Self.rowHeight, width: bounds.width - Self.padding * 2, height: Self.rowHeight)
        let position = "\(page.selected + 1)/\(page.count)" as NSString
        let width = position.size(withAttributes: [.font: Self.numberFont]).width
        drawText(position as String, font: Self.numberFont, color: .secondaryLabelColor, x: rect.maxX - width - 6, in: rect)
    }

    /// rect の行の高さの中ほどに、x から描く
    private func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(at: NSPoint(x: x, y: rect.minY + (rect.height - height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard let page else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = Int(floor((point.y - Self.padding) / Self.rowHeight))
        guard page.numbered.indices.contains(row) else { return }
        onClick?(page.numbered[row].index)
    }
}
