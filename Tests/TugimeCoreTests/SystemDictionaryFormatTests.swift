import Foundation
import SystemDictionaryLayout
import Testing
@testable import TugimeCore

/// 引くときに範囲を確かめない値が区画の外を指すシステム辞書は、読み込みで形が違うと分かる。引くときに区画の外を読まない
@Suite struct SystemDictionaryFormatTests {
    /// 品詞 1 つ、読み「あ」「い」に語「亜」「伊」が 1 つずつの辞書。どの欄も、変えなければ正しい形
    struct Fields: Sendable, CustomStringConvertible {
        var posCount: UInt32 = 1
        var maxReadingChars: UInt32 = 1
        var periodId: UInt32 = 0
        var lid: UInt16 = 0
        var rid: UInt16 = 0
        var surfaceOffset: UInt32 = 0
        var surfaceLength: UInt32 = 3
        var readingOffsets: [UInt32] = [0, 3, 6]
        var entryStarts: [UInt32] = [0, 1, 2]
        var description: String {
            "pos \(posCount) maxReading \(maxReadingChars) period \(periodId) lid \(lid) rid \(rid) surface \(surfaceOffset)+\(surfaceLength) readingOffsets \(readingOffsets) entryStarts \(entryStarts)"
        }
    }

    static func header(_ fields: Fields) -> [UInt32] {
        typealias F = SystemDictionaryLayout.Field
        var header = [UInt32](repeating: 0, count: SystemDictionaryLayout.headerCount)
        header[F.magic.rawValue] = SystemDictionaryLayout.magic
        header[F.version.rawValue] = SystemDictionaryLayout.version
        header[F.posCount.rawValue] = fields.posCount
        header[F.readingCount.rawValue] = 2
        header[F.entryCount.rawValue] = 2
        header[F.readingBytes.rawValue] = 6
        header[F.surfaceBytes.rawValue] = 6
        header[F.maxReadingChars.rawValue] = fields.maxReadingChars
        header[F.periodId.rawValue] = fields.periodId
        return header
    }

    static func bytes(_ fields: Fields) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ values: [T]) {
            for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        }
        func align() { data.append(contentsOf: [UInt8](repeating: 0, count: SystemDictionaryLayout.aligned(data.count) - data.count)) }
        append(header(fields))
        let pos = Int(fields.posCount)
        append([Int16](repeating: 0, count: pos * pos))
        align()
        append([UInt8](repeating: 0, count: pos * pos))
        align()
        append(fields.readingOffsets)
        append(fields.entryStarts)
        // 2 つ目の語は正しい形のまま。1 つ目の語の欄だけを変える
        append([fields.lid, fields.rid, 0, 0])
        append([fields.surfaceOffset, fields.surfaceLength])
        append([UInt16(0), 0, 0, 0])
        append([UInt32(3), 3])
        data.append(contentsOf: Array("あい".utf8))
        align()
        data.append(contentsOf: Array("亜伊".utf8))
        align()
        return data
    }

    static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tugime-dictionary-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    static func isWrongFormat(_ data: Data) throws -> Bool {
        let url = try write(data)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try SystemDictionary(url: url)
            return false
        } catch SystemDictionary.LoadError.wrongFormat {
            return true
        }
    }

    @Test func readsAWellFormedDictionary() throws {
        let url = try Self.write(Self.bytes(Fields()))
        defer { try? FileManager.default.removeItem(at: url) }
        let dictionary = try SystemDictionary(url: url)
        let found = ["あ", "い"].map { reading in
            Array(reading.utf8).withUnsafeBufferPointer { dictionary.lookup($0) }.map { dictionary.surface(dictionary.entry($0.lowerBound)) }
        }
        #expect(found == ["亜", "伊"])
    }

    @Test(arguments: [
        Fields(maxReadingChars: 0),
        Fields(periodId: 1),
        Fields(lid: 1),
        Fields(rid: 1),
        Fields(surfaceOffset: 4),
        Fields(surfaceLength: 7),
        Fields(readingOffsets: [1, 3, 6]),
        Fields(readingOffsets: [0, 3, 5]),
        Fields(readingOffsets: [0, 7, 6]),
        Fields(entryStarts: [1, 1, 2]),
        Fields(entryStarts: [0, 1, 1]),
        Fields(entryStarts: [0, 5, 2]),
    ])
    func rejectsValuesOutsideTheSections(fields: Fields) throws {
        #expect(try Self.isWrongFormat(Self.bytes(fields)))
    }

    /// 品詞の数が、1 から UInt16 の ID で表せる数までの範囲の外にある辞書。区画の大きさ（品詞の数の 2 乗）を計算する前に弾くことを確かめるので、
    /// 区画を書かずに先頭だけにする
    @Test(arguments: [UInt32(0), UInt32(UInt16.max) + 2, UInt32.max])
    func rejectsPartOfSpeechCountsOutsideTheIds(posCount: UInt32) throws {
        var header = Self.header(Fields())
        header[SystemDictionaryLayout.Field.posCount.rawValue] = posCount
        var data = Data()
        for value in header { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        #expect(try Self.isWrongFormat(data))
    }
}
