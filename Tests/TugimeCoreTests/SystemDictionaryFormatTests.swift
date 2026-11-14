import Foundation
import SystemDictionaryLayout
import Testing
@testable import TugimeCore

/// 引くときに範囲を確かめない値が区画の外を指すシステム辞書は、読み込みで形が違うと分かる。引くときに区画の外を読まない
@Suite struct SystemDictionaryFormatTests {
    /// 品詞 1 つ、読み「あ」に語「亜」が 1 つの辞書
    struct Fields {
        var posCount: UInt32 = 1
        var maxReadingChars: UInt32 = 1
        var periodId: UInt32 = 0
        var lid: UInt16 = 0
        var rid: UInt16 = 0
        var surfaceLength: UInt32 = 3
        var lastEntryStart: UInt32 = 1
    }

    func file(_ fields: Fields) throws -> URL {
        typealias F = SystemDictionaryLayout.Field
        let reading = Array("あ".utf8)
        let surface = Array("亜".utf8)
        var header = [UInt32](repeating: 0, count: SystemDictionaryLayout.headerCount)
        header[F.magic.rawValue] = SystemDictionaryLayout.magic
        header[F.version.rawValue] = SystemDictionaryLayout.version
        header[F.posCount.rawValue] = fields.posCount
        header[F.readingCount.rawValue] = 1
        header[F.entryCount.rawValue] = 1
        header[F.readingBytes.rawValue] = UInt32(reading.count)
        header[F.surfaceBytes.rawValue] = UInt32(surface.count)
        header[F.maxReadingChars.rawValue] = fields.maxReadingChars
        header[F.periodId.rawValue] = fields.periodId
        var data = Data()
        func append<T: FixedWidthInteger>(_ values: [T]) {
            for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        }
        func align() { data.append(contentsOf: [UInt8](repeating: 0, count: SystemDictionaryLayout.aligned(data.count) - data.count)) }
        append(header)
        let pos = Int(fields.posCount)
        append([Int16](repeating: 0, count: pos * pos))
        align()
        append([UInt8](repeating: 0, count: pos * pos))
        align()
        append([UInt32(0), UInt32(reading.count)])
        append([UInt32(0), fields.lastEntryStart])
        append([fields.lid, fields.rid, 0, 0])
        append([UInt32(0), fields.surfaceLength])
        data.append(contentsOf: reading)
        align()
        data.append(contentsOf: surface)
        align()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tugime-dictionary-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    func isWrongFormat(_ fields: Fields) throws -> Bool {
        let url = try file(fields)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try SystemDictionary(url: url)
            return false
        } catch SystemDictionary.LoadError.wrongFormat {
            return true
        }
    }

    @Test func readsAWellFormedDictionary() throws {
        let url = try file(Fields())
        defer { try? FileManager.default.removeItem(at: url) }
        let dictionary = try SystemDictionary(url: url)
        let range = Array("あ".utf8).withUnsafeBufferPointer { dictionary.lookup($0) }
        #expect(range == 0..<1)
        #expect(range.map { dictionary.surface(dictionary.entry($0.lowerBound)) } == "亜")
    }

    @Test(arguments: [
        Fields(posCount: 0),
        Fields(maxReadingChars: 0),
        Fields(periodId: 1),
        Fields(lid: 1),
        Fields(rid: 1),
        Fields(surfaceLength: 4),
        Fields(lastEntryStart: 2),
    ])
    func rejectsValuesOutsideTheSections(fields: Fields) throws {
        #expect(try isWrongFormat(fields))
    }
}
