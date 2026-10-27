import Cocoa
import SwiftUI

/// 入力メニューの「設定…」で開く窓。プロセスに 1 つ
let settingsWindow = SettingsWindow()

/// 設定を集める窓。入力メソッドは LSBackgroundOnly で前に出られないので、開いている間だけ accessory にする
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// macOS 14 から activate は依頼で、前のアプリが譲らなければ通らないことがある（AppKit Release Notes for macOS 14）。
    /// 入力メニューから開くときに前にいるのは打っていたアプリで、tugime には譲らない。
    /// 通らなくても窓は orderFrontRegardless で最前面に出し、利用者が窓を押せばそこで active になる
    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String else {
            fatalError("Info.plist に CFBundleName が無い")
        }
        window.title = "\(name) の設定"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
}

private struct SettingsView: View {
    var body: some View {
        Form {
            Section("辞書") {
                LabeledContent {
                    Button("編集…") { userDictionaryFile.openInEditor() }
                } label: {
                    Text("tugime の辞書")
                    Text("打鍵と表記を 1 行に 1 語ずつ書く")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}
