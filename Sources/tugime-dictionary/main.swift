import Foundation
import SystemDictionaryLayout

// Mozc の OSS 辞書・連接の表・文節の境目の規則を、SystemDictionaryLayout の並びの 1 つのファイルにする。
// 使い方: tugime-dictionary <Mozc の src> <書き出すファイル>。入力は bun scripts/fetch-dictionary.ts が版を固定して取得する

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tugime-dictionary: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard args.count == 2 else { fail("引数は <Mozc の src> <書き出すファイル>") }
let source = URL(fileURLWithPath: args[args.startIndex])
let output = URL(fileURLWithPath: args[args.startIndex + 1])
let dictionaryDirectory = source.appendingPathComponent("data/dictionary_oss")
let started = Date()

func log(_ message: String) {
    FileHandle.standardError.write(Data(String(format: "[%.1fs] %@\n", Date().timeIntervalSince(started), message).utf8))
}

func read(_ url: URL) -> Data {
    do { return try Data(contentsOf: url) } catch { fail("\(url.path) を読めない: \(error)") }
}

/// 改行で切った行。空の行は除く
func lines(_ data: Data) -> [ArraySlice<UInt8>] {
    [UInt8](data).split(separator: 0x0A)
}

func text(_ bytes: some Collection<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

// 品詞。id.def の行は「ID 品詞」
let posNames: [String] = lines(read(dictionaryDirectory.appendingPathComponent("id.def"))).enumerated().map { index, line in
    let fields = line.split(separator: 0x20, maxSplits: 1)
    guard fields.count == 2, Int(text(fields[0])) == index else { fail("id.def の行を読めない: \(text(line))") }
    return text(fields[1])
}
let posCount = posNames.count
func posId(_ name: String) -> UInt32 {
    guard let id = posNames.firstIndex(of: name) else { fail("id.def に無い品詞: \(name)") }
    return UInt32(id)
}
log("品詞 \(posCount)")

// 連接。1 行目が品詞の数、続いて 前の語の右 ID × 品詞の数 + 今の語の左 ID の順のコスト
let connectionLines = lines(read(dictionaryDirectory.appendingPathComponent("connection_single_column.txt")))
guard let first = connectionLines.first, Int(text(first)) == posCount, connectionLines.count == posCount * posCount + 1 else {
    fail("連接の表の大きさが品詞の数 \(posCount) と合わない")
}
let connection: [Int16] = connectionLines.dropFirst().map { line in
    guard let cost = Int16(text(line)) else { fail("連接のコストが Int16 に収まらない: \(text(line))") }
    return cost
}
log("連接")

// 文節の境目。gen_segmenter_code.py と同じく、規則を上から読み、左を前の語の右 ID、右を今の語の左 ID の品詞に先頭一致で当て、
// 最初に当たった規則で決める。当たらなければ境目にする。BOS/EOS（ID 0）の前後は常に境目
let rules: [(left: [Bool], right: [Bool], boundary: Bool)] = lines(read(source.appendingPathComponent("data/rules/segmenter.def")))
    .map(text)
    .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    .map { line in
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 3 else { fail("segmenter.def の行を読めない: \(line)") }
        func matches(_ pattern: String) -> [Bool] {
            if pattern == "*" { return Array(repeating: true, count: posCount) }
            guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern.replacingOccurrences(of: "*", with: "[^,]+") + ")") else {
                fail("segmenter.def の型を読めない: \(pattern)")
            }
            let hits = posNames.map { regex.firstMatch(in: $0, options: .anchored, range: NSRange(location: 0, length: $0.utf16.count)) != nil }
            guard hits.contains(true) else { fail("segmenter.def の型に当たる品詞が無い: \(pattern)") }
            return hits
        }
        return (matches(fields[0]), matches(fields[1]), fields[2].lowercased() == "true")
    }
// 規則を下から順に、当たる組すべてに結果を書く。上の規則ほど後に書くので、最初に当たった規則で決まる
var boundary = [UInt8](repeating: 1, count: posCount * posCount)
for rule in rules.reversed() {
    let lids = (1..<posCount).filter { rule.right[$0] }
    let value: UInt8 = rule.boundary ? 1 : 0
    for rid in 1..<posCount where rule.left[rid] {
        for lid in lids { boundary[rid * posCount + lid] = value }
    }
}
log("文節の規則 \(rules.count)")

// 辞書。行は「読み \t 左 ID \t 右 ID \t コスト \t 表記」。同じ読み・品詞・表記はコストの小さい方だけ残す。
// 6 つ目の欄が SPELLING_CORRECTION の行は、別の綴りの読みで正しい表記を出す補正の語なので入れない（読みは利用者の綴りだけで決まる）
let spellingCorrection = Array("SPELLING_CORRECTION".utf8)
struct Word {
    var reading: ArraySlice<UInt8>
    var lid: UInt16
    var rid: UInt16
    var cost: Int16
    var surface: ArraySlice<UInt8>
}
var words: [Word] = []
let dictionaryFiles = (0...9).map { dictionaryDirectory.appendingPathComponent(String(format: "dictionary%02d.txt", $0)) }
for file in dictionaryFiles {
    for line in lines(read(file)) {
        let fields = line.split(separator: 0x09, omittingEmptySubsequences: false)
        if fields.count == 6, fields[5].elementsEqual(spellingCorrection) { continue }
        guard fields.count == 5, let lid = UInt16(text(fields[1])), let rid = UInt16(text(fields[2])), let cost = Int16(text(fields[3])),
              Int(lid) < posCount, Int(rid) < posCount
        else { fail("\(file.lastPathComponent) の行を読めない: \(text(line))") }
        words.append(Word(reading: fields[0], lid: lid, rid: rid, cost: cost, surface: fields[4]))
    }
}
let lineCount = words.count
words.sort { a, b in
    if a.reading != b.reading { return a.reading.lexicographicallyPrecedes(b.reading) }
    if a.cost != b.cost { return a.cost < b.cost }
    if a.lid != b.lid { return a.lid < b.lid }
    if a.rid != b.rid { return a.rid < b.rid }
    return a.surface.lexicographicallyPrecedes(b.surface)
}
// 読みの中はコストの小さい順なので、同じ品詞・表記の 2 つ目以降を捨てる
var kept: [Word] = []
var seen: Set<[UInt8]> = []
for word in words {
    if kept.last?.reading != word.reading { seen = [] }
    let key = withUnsafeBytes(of: (word.lid, word.rid)) { Array($0) } + word.surface
    if seen.insert(key).inserted { kept.append(word) }
}
log("辞書の行 \(lineCount)、語 \(kept.count)")

var readingOffsets: [UInt32] = []
var entryStarts: [UInt32] = []
var readingBytes: [UInt8] = []
var surfaceBytes: [UInt8] = []
var surfaces: [ArraySlice<UInt8>: (offset: UInt32, length: UInt32)] = [:]
var entries: [UInt8] = []
entries.reserveCapacity(kept.count * SystemDictionaryLayout.entrySize)
var maxReadingChars = 0
for (index, word) in kept.enumerated() {
    if index == 0 || kept[index - 1].reading != word.reading {
        readingOffsets.append(UInt32(readingBytes.count))
        entryStarts.append(UInt32(index))
        readingBytes.append(contentsOf: word.reading)
        // UTF-8 の続きのバイト（10xxxxxx）以外を数えると文字の数になる
        maxReadingChars = max(maxReadingChars, word.reading.filter { $0 & 0xC0 != 0x80 }.count)
    }
    let surface = surfaces[word.surface] ?? {
        let placed = (UInt32(surfaceBytes.count), UInt32(word.surface.count))
        surfaceBytes.append(contentsOf: word.surface)
        surfaces[word.surface] = placed
        return placed
    }()
    withUnsafeBytes(of: (word.lid.littleEndian, word.rid.littleEndian, word.cost.littleEndian, UInt16(0), surface.offset.littleEndian, surface.length.littleEndian)) {
        precondition($0.count == SystemDictionaryLayout.entrySize, "語の大きさが並びと違う")
        entries.append(contentsOf: $0)
    }
}
readingOffsets.append(UInt32(readingBytes.count))
entryStarts.append(UInt32(kept.count))

typealias F = SystemDictionaryLayout.Field
var header = [UInt32](repeating: 0, count: SystemDictionaryLayout.headerCount)
header[F.magic.rawValue] = SystemDictionaryLayout.magic
header[F.version.rawValue] = SystemDictionaryLayout.version
header[F.posCount.rawValue] = UInt32(posCount)
header[F.readingCount.rawValue] = UInt32(readingOffsets.count - 1)
header[F.entryCount.rawValue] = UInt32(kept.count)
header[F.readingBytes.rawValue] = UInt32(readingBytes.count)
header[F.surfaceBytes.rawValue] = UInt32(surfaceBytes.count)
header[F.maxReadingChars.rawValue] = UInt32(maxReadingChars)
header[F.numberId.rawValue] = posId("名詞,数,アラビア数字,*,*,*,*")
header[F.nounId.rawValue] = posId("名詞,一般,*,*,*,*,*")
header[F.properNounId.rawValue] = posId("名詞,固有名詞,一般,*,*,*,*")
header[F.periodId.rawValue] = posId("記号,句点,*,*,*,*,。")

let bodies: [SystemDictionaryLayout.Section: [UInt8]] = [
    .connection: connection.withUnsafeBytes { Array($0) },
    .boundary: boundary,
    .readingOffsets: readingOffsets.withUnsafeBytes { Array($0) },
    .entryStarts: entryStarts.withUnsafeBytes { Array($0) },
    .entries: entries,
    .readingBytes: readingBytes,
    .surfaceBytes: surfaceBytes,
]
var file = Data(header.withUnsafeBytes { Array($0) })
for section in SystemDictionaryLayout.Section.allCases {
    let body = bodies[section]!
    precondition(body.count == SystemDictionaryLayout.size(of: section, header: header), "区画の大きさが並びと違う: \(section)")
    file.append(contentsOf: body)
    file.append(contentsOf: [UInt8](repeating: 0, count: SystemDictionaryLayout.aligned(body.count) - body.count))
}
precondition(file.count == SystemDictionaryLayout.offsets(header: header).total, "ファイルの大きさが並びと違う")
do { try file.write(to: output, options: .atomic) } catch { fail("\(output.path) に書けない: \(error)") }
log("書き出し \(output.path) \(file.count / 1024 / 1024)MiB（読み \(readingOffsets.count - 1)、表記 \(surfaces.count)、最長の読み \(maxReadingChars) 文字）")
