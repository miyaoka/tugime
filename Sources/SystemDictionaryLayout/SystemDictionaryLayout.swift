/// システム辞書のファイルの並び。書き出す tugime-dictionary と、mmap で読む TugimeCore の SystemDictionary が共有する。
/// 値はすべてリトルエンディアンで、区画は 4 バイト境界に揃える。並びを変えたら version を上げる
public enum SystemDictionaryLayout {
    public static let magic: UInt32 = 0x444c_4754
    public static let version: UInt32 = 1
    /// 先頭の UInt32 の数。使わない欄は 0
    public static let headerCount = 16
    public static var headerSize: Int { headerCount * 4 }

    /// 先頭の UInt32 の欄の位置
    public enum Field: Int {
        case magic, version, posCount, readingCount, entryCount, readingBytes, surfaceBytes, maxReadingChars
        /// 文脈の始まりと区間の終わりに使う品詞 ID
        case numberId, nounId, properNounId, periodId
    }

    /// 語 1 つの大きさ。lid UInt16, rid UInt16, cost Int16, 詰め物 UInt16, 表記の位置 UInt32, 表記の長さ UInt32
    public static let entrySize = 16

    public static func aligned(_ size: Int) -> Int { (size + 3) & ~3 }

    /// 区画の並び
    public enum Section: CaseIterable {
        /// Int16[pos × pos]。前の語の右 ID × pos + 今の語の左 ID
        case connection
        /// UInt8[pos × pos]。連接と同じ並びで、1 なら文節の境目
        case boundary
        /// UInt32[読みの数 + 1]。読みのバイト列の位置。読みは UTF-8 のバイト順に並ぶ
        case readingOffsets
        /// UInt32[読みの数 + 1]。読みごとの語の範囲の始まり。語は読みの中でコストの小さい順
        case entryStarts
        case entries
        case readingBytes
        case surfaceBytes
    }

    /// 区画の大きさ（バイト、揃える前）
    public static func size(of section: Section, header: [UInt32]) -> Int {
        let pos = Int(header[Field.posCount.rawValue])
        let readings = Int(header[Field.readingCount.rawValue])
        switch section {
        case .connection: return pos * pos * 2
        case .boundary: return pos * pos
        case .readingOffsets, .entryStarts: return (readings + 1) * 4
        case .entries: return Int(header[Field.entryCount.rawValue]) * entrySize
        case .readingBytes: return Int(header[Field.readingBytes.rawValue])
        case .surfaceBytes: return Int(header[Field.surfaceBytes.rawValue])
        }
    }

    /// 区画ごとのファイルの中の位置と、ファイル全体の大きさ
    public static func offsets(header: [UInt32]) -> (sections: [Section: Int], total: Int) {
        var offset = headerSize
        var sections: [Section: Int] = [:]
        for section in Section.allCases {
            sections[section] = offset
            offset += aligned(size(of: section, header: header))
        }
        return (sections, offset)
    }
}
