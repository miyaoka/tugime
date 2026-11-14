import Foundation
import SystemDictionaryLayout

/// システム辞書。bun scripts/fetch-dictionary.ts が組み立てたファイルを mmap で引く。読むだけなので、変換器どうしで共有してよい
public final class SystemDictionary: @unchecked Sendable {
    /// 入力メソッドはバンドルの Contents/Resources の directory に、開発の道具はリポジトリの直下の directory に置く
    public static let directory = "dictionary"
    public static let fileName = "tugime-dictionary.bin"

    /// リポジトリの直下から見た、bun scripts/fetch-dictionary.ts が組み立てたファイル
    public static func inRepository(_ root: URL) -> URL {
        root.appendingPathComponent(".dictionary").appendingPathComponent(fileName)
    }

    public enum LoadError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case wrongFormat(String)
        public var description: String {
            switch self {
            case .cannotOpen(let path): "システム辞書を開けない: \(path)。bun scripts/fetch-dictionary.ts で組み立てる"
            case .wrongFormat(let path): "システム辞書の形が違う: \(path)。bun scripts/fetch-dictionary.ts で組み立て直す"
            }
        }
    }

    let posCount: Int
    let maxReadingChars: Int
    let numberId: UInt16
    let nounId: UInt16
    let properNounId: UInt16
    let periodId: UInt16
    private let mapped: UnsafeMutableRawPointer
    private let length: Int
    private let readingCount: Int
    private let connection: UnsafePointer<Int16>
    private let boundary: UnsafePointer<UInt8>
    private let readingOffsets: UnsafePointer<UInt32>
    private let entryStarts: UnsafePointer<UInt32>
    private let entries: UnsafeRawPointer
    private let readingBytes: UnsafePointer<UInt8>
    private let surfaceBytes: UnsafePointer<UInt8>

    struct Entry {
        var lid: UInt16
        var rid: UInt16
        var cost: Int32
        var surfaceOffset: Int
        var surfaceLength: Int
    }

    public init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw LoadError.cannotOpen(url.path) }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size >= SystemDictionaryLayout.headerSize else { throw LoadError.wrongFormat(url.path) }
        let length = Int(status.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else { throw LoadError.cannotOpen(url.path) }
        typealias F = SystemDictionaryLayout.Field
        let header = Array(UnsafeBufferPointer(start: mapped.assumingMemoryBound(to: UInt32.self), count: SystemDictionaryLayout.headerCount))
        // 品詞 ID は UInt16 で持つ。品詞の数を先に確かめておくと、区画の大きさ（品詞の数の 2 乗）の計算もあふれない
        let pos = Int(header[F.posCount.rawValue])
        let ids = [F.numberId, .nounId, .properNounId, .periodId].map { Int(header[$0.rawValue]) }
        guard header[F.magic.rawValue] == SystemDictionaryLayout.magic, header[F.version.rawValue] == SystemDictionaryLayout.version,
              (1...Int(UInt16.max) + 1).contains(pos), ids.allSatisfy({ $0 < pos }), header[F.maxReadingChars.rawValue] >= 1
        else {
            munmap(mapped, length)
            throw LoadError.wrongFormat(url.path)
        }
        let layout = SystemDictionaryLayout.offsets(header: header)
        guard layout.total == length else {
            munmap(mapped, length)
            throw LoadError.wrongFormat(url.path)
        }
        self.mapped = mapped
        self.length = length
        posCount = Int(header[F.posCount.rawValue])
        readingCount = Int(header[F.readingCount.rawValue])
        maxReadingChars = Int(header[F.maxReadingChars.rawValue])
        numberId = UInt16(header[F.numberId.rawValue])
        nounId = UInt16(header[F.nounId.rawValue])
        properNounId = UInt16(header[F.properNounId.rawValue])
        periodId = UInt16(header[F.periodId.rawValue])
        func section(_ section: SystemDictionaryLayout.Section) -> UnsafeRawPointer { UnsafeRawPointer(mapped + layout.sections[section]!) }
        connection = section(.connection).assumingMemoryBound(to: Int16.self)
        boundary = section(.boundary).assumingMemoryBound(to: UInt8.self)
        readingOffsets = section(.readingOffsets).assumingMemoryBound(to: UInt32.self)
        entryStarts = section(.entryStarts).assumingMemoryBound(to: UInt32.self)
        entries = section(.entries)
        readingBytes = section(.readingBytes).assumingMemoryBound(to: UInt8.self)
        surfaceBytes = section(.surfaceBytes).assumingMemoryBound(to: UInt8.self)
        guard isWellFormed(entryCount: Int(header[F.entryCount.rawValue]), readingByteCount: Int(header[F.readingBytes.rawValue]), surfaceByteCount: Int(header[F.surfaceBytes.rawValue])) else {
            throw LoadError.wrongFormat(url.path)
        }
    }

    /// 引くときに範囲を確かめない値（読みと語の範囲、品詞 ID、表記の位置）が、どれも区画の中を指すか。
    /// 外を指すと、引くときに止まらずに区画の外を読む
    private func isWellFormed(entryCount: Int, readingByteCount: Int, surfaceByteCount: Int) -> Bool {
        guard readingOffsets[0] == 0, Int(readingOffsets[readingCount]) == readingByteCount,
              entryStarts[0] == 0, Int(entryStarts[readingCount]) == entryCount
        else { return false }
        for i in 0..<readingCount where readingOffsets[i] > readingOffsets[i + 1] || entryStarts[i] > entryStarts[i + 1] {
            return false
        }
        for index in 0..<entryCount {
            let e = entry(index)
            guard Int(e.lid) < posCount, Int(e.rid) < posCount, e.surfaceOffset + e.surfaceLength <= surfaceByteCount else { return false }
        }
        return true
    }

    deinit {
        munmap(mapped, length)
    }

    @inline(__always) func connection(_ rid: UInt16, _ lid: UInt16) -> Int32 {
        Int32(connection[Int(rid) * posCount + Int(lid)])
    }

    @inline(__always) func isBoundary(_ rid: UInt16, _ lid: UInt16) -> Bool {
        boundary[Int(rid) * posCount + Int(lid)] != 0
    }

    @inline(__always) func entry(_ index: Int) -> Entry {
        let p = entries + index * SystemDictionaryLayout.entrySize
        return Entry(
            lid: UInt16(littleEndian: p.loadUnaligned(as: UInt16.self)),
            rid: UInt16(littleEndian: p.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
            cost: Int32(Int16(littleEndian: p.loadUnaligned(fromByteOffset: 4, as: Int16.self))),
            surfaceOffset: Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
            surfaceLength: Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
        )
    }

    func surface(_ entry: Entry) -> String {
        String(decoding: UnsafeBufferPointer(start: surfaceBytes + entry.surfaceOffset, count: entry.surfaceLength), as: UTF8.self)
    }

    /// 読み i と key のバイト列の大小
    @inline(__always) private func compare(_ i: Int, _ key: UnsafeBufferPointer<UInt8>) -> Int32 {
        let start = Int(readingOffsets[i])
        let count = Int(readingOffsets[i + 1]) - start
        let order = memcmp(readingBytes + start, key.baseAddress!, min(count, key.count))
        return order != 0 ? order : Int32(count - key.count)
    }

    /// key と同じ読みの語の範囲
    func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        var low = 0
        var high = readingCount
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, key) < 0 { low = mid + 1 } else { high = mid }
        }
        guard low < readingCount, compare(low, key) == 0 else { return nil }
        return Int(entryStarts[low])..<Int(entryStarts[low + 1])
    }
}
