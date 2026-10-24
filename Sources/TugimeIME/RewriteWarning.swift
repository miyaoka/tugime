import Cocoa
import InputMethodKit

/// 打っている途中の表示が打った読みと合わないときに、未確定の文字列の下に出す小さな窓
final class RewriteWarning {
    static let message = "入力と違う変換"
    /// 窓の中の文字の余白と、行から窓までの間
    private static let padding = NSSize(width: 12, height: 8)
    private static let gap: CGFloat = 6

    private var panel: NSPanel?

    /// 未確定の文字列の先頭の行の下に、アプリの窓より 1 つ上の level で出す。アプリが位置を返さない（無限大や高さ 0）ときは出さない
    func show(below client: IMKTextInput) {
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &line)
        guard line.minX.isFinite, line.minY.isFinite, line.height > 0 else {
            hide()
            return
        }
        let label = NSTextField(labelWithString: Self.message)
        label.font = .systemFont(ofSize: 13)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + Self.padding.width * 2, height: label.frame.height + Self.padding.height * 2)
        let panel = panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(client.windowLevel()) + 1)
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.ignoresMouseEvents = true
        panel.setContentSize(size)
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        label.frame.origin = NSPoint(x: Self.padding.width, y: Self.padding.height)
        panel.contentView?.addSubview(label)
        panel.setFrameOrigin(NSPoint(x: line.minX, y: line.minY - size.height - Self.gap))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
