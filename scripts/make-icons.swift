// 入力メニューのアイコンを文字から作る。引数は出力先ディレクトリ
import AppKit

let icons = ["japanese": "つ", "roman": "A"]
let size = NSSize(width: 32, height: 32)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("使い方: swift make-icons.swift <出力先>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

for (name, glyph) in icons {
    let image = NSImage(size: size, flipped: false) { rect in
        let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.black])
        let bounds = text.size()
        text.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2))
        return true
    }
    guard let tiff = image.tiffRepresentation else {
        FileHandle.standardError.write(Data("\(name) のアイコンを作れない\n".utf8))
        exit(1)
    }
    try tiff.write(to: outDir.appendingPathComponent("\(name).tiff"))
    print("\(name).tiff")
}
