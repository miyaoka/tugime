import Cocoa
import InputMethodKit
import TugimeCore

/// 打っている途中の表示が打った読みと合わないときに、未確定の文字列の下に出す小さな窓
final class RewriteWarning {
    /// 窓の中の文字の余白
    private static let padding = NSSize(width: 12, height: 8)

    private var panel: NSPanel?

    /// 未確定の文字列の先頭の行の下に出す。アプリが位置を返さないときは出さない
    func show(below client: IMKTextInput) {
        let label = NSTextField(labelWithString: Segmenter.LiveDisplay.warning)
        label.font = .systemFont(ofSize: 13)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + Self.padding.width * 2, height: label.frame.height + Self.padding.height * 2)
        let panel = panel ?? PanelPlacement.makePanel()
        panel.ignoresMouseEvents = true
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        label.frame.origin = NSPoint(x: Self.padding.width, y: Self.padding.height)
        panel.contentView?.addSubview(label)
        self.panel = panel
        PanelPlacement.show(panel, size: size, below: client)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
