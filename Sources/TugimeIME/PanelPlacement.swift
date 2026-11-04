import Cocoa
import InputMethodKit

/// 未確定の文字列の下に出す窓（候補の窓・警告の窓）の作り方と置き方
enum PanelPlacement {
    /// 行から窓までの間
    static let gap: CGFloat = 6

    /// 枠が無く、出してもアプリからフォーカスを奪わない窓
    static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        return panel
    }

    /// 窓を大きさ size にし、未確定の文字列の characterIndex 文字目（UTF-16 の位置）の行の下に、その文字に左端をそろえて、
    /// アプリの窓より 1 つ上の level で出す。行の下に収まらなければ行の上に置き、左右と上は画面の中へ詰める。
    /// アプリが位置を返さない（無限大や高さ 0）ときは出さない
    static func show(_ panel: NSPanel, size: NSSize, below client: IMKTextInput, characterIndex: Int = 0) {
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &line)
        guard line.minX.isFinite, line.minY.isFinite, line.height > 0 else {
            panel.orderOut(nil)
            return
        }
        var origin = NSPoint(x: line.minX, y: line.minY - size.height - gap)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(line) } ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = line.maxY + gap }
            origin.y = min(origin.y, visible.maxY - size.height)
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        }
        panel.level = NSWindow.Level(rawValue: Int(client.windowLevel()) + 1)
        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }
}
