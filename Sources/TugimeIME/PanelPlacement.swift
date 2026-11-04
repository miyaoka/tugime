import Cocoa
import InputMethodKit

/// 未確定の文字列の下に出す窓（候補の窓・警告の窓）の置き方
enum PanelPlacement {
    /// 行から窓までの間
    static let gap: CGFloat = 6

    /// 大きさ size の窓を置く左下の点。未確定の文字列の characterIndex 文字目（UTF-16 の位置）の行の下に、その文字に左端をそろえて置く。
    /// 収まらなければ行の上に置いて、左右と上は画面の中へ詰める。アプリが位置を返さない（無限大や高さ 0）ときは nil
    static func origin(below client: IMKTextInput, characterIndex: Int = 0, size: NSSize) -> NSPoint? {
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &line)
        guard line.minX.isFinite, line.minY.isFinite, line.height > 0 else { return nil }
        var origin = NSPoint(x: line.minX, y: line.minY - size.height - gap)
        guard let visible = (NSScreen.screens.first { $0.frame.intersects(line) } ?? NSScreen.main)?.visibleFrame else { return origin }
        if origin.y < visible.minY { origin.y = line.maxY + gap }
        origin.y = min(origin.y, visible.maxY - size.height)
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        return origin
    }

    /// 枠が無く、出してもアプリからフォーカスを奪わない窓。アプリの窓より 1 つ上の level に出す
    static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        return panel
    }
}
