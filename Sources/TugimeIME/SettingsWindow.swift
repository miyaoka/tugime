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
                if DictionarySync.isAvailable {
                    LabeledContent {
                        Button("写す…") { DictionarySync.run() }
                    } label: {
                        Text("配布版の辞書を写す")
                        Text("開発版の辞書を、配布版の辞書で置き換える")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

/// 配布版の辞書を開発版の辞書へ写す道具（TugimeSync）。開発版にだけ同梱するので、同梱されているかで出すかを決める
enum DictionarySync {
    /// 置き場所は Info.plist の TugimeSyncApp に書いてある。組み立てと検査も同じキーを読む
    static let app: URL = {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "TugimeSyncApp") as? String else {
            fatalError("Info.plist に TugimeSyncApp が無い")
        }
        return Bundle.main.bundleURL.appendingPathComponent(path)
    }()

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: app.path) }

    /// 終わるのを待っている道具の監視
    private static var watching: NSKeyValueObservation?

    /// 置き換えてよいかを確かめてから、道具を起動する。
    /// 子プロセスとして起動すると IME の Sandbox を引き継いで配布版のコンテナを読めないので、LaunchServices で起動する
    static func run() {
        let confirm = NSAlert()
        confirm.messageText = "配布版の辞書を写す"
        confirm.informativeText = "開発版の辞書を、配布版の辞書で置き換えます。開発版にだけある語は消えます。"
        confirm.addButton(withTitle: "置き換える")
        confirm.addButton(withTitle: "やめる")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let url = userDictionaryFile.url
        do {
            // 道具は写す先のディレクトリを作らない（Sandbox の外で、コンテナの中のパスを作らせない）ので、自分のコンテナに先に作る
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            report("配布版の辞書を写せない", "\(url.path)\n\(error.localizedDescription)")
            return
        }
        let before = modified(url)
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { running, error in
            Task { @MainActor in
                if let error {
                    report("配布版の辞書を写す道具を起動できない", "\(app.path)\n\(error.localizedDescription)")
                    return
                }
                guard let running else {
                    report("配布版の辞書を写す道具を起動できない", app.path)
                    return
                }
                watch(running, url: url, before: before)
            }
        }
    }

    /// 道具が終わったら、辞書が書き換わったかで結果を知らせる。道具は画面を出さず、失敗の理由はログに書く
    private static func watch(_ running: NSRunningApplication, url: URL, before: Date?) {
        watching = running.observe(\.isTerminated, options: [.initial]) { running, _ in
            guard running.isTerminated else { return }
            Task { @MainActor in
                guard watching != nil else { return }
                watching = nil
                if modified(url) != before {
                    report("配布版の辞書を写した", "次に打ち始めたときから効きます。")
                } else {
                    report("配布版の辞書を写せない", "理由は Console.app で tugime-sync を検索すると出ます。")
                }
            }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private static func report(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
