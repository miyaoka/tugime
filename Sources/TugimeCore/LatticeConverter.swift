import Foundation

/// システム辞書の語の格子から、最良の語の列（区切りの採点・文節・表記）と上位の列（候補の窓）を求める変換器。
/// 道のコストは Mozc と同じく「前のコスト + 連接（前の語の右 ID, 今の語の左 ID）+ 語のコスト」。学習しないので、同じかなには常に同じ結果を返す
final class LatticeConverter: JapaneseConverting {
    /// 点 = −コスト ÷ scale。英語の綴りの点（Segmenter.englishWeight）と釣り合う尺度
    static let scale = 550.0
    /// 辞書に無い 1 かなを、かなのまま通す道のコスト
    static let unknownCost: Int32 = 10000
    /// 利用者の語のコストの基準。Mozc の固有名詞（user_pos.def）。登録数 N による 500·ln(N+1) を足す（user_dictionary.cc）
    static let userBaseCost = 1500.0
    /// 利用者の語 1 つの点の基準。登録数による減点と前後の連接を含まない（Segmenter.registeredScore の元）
    static let userWordValue = -userBaseCost / scale
    /// 候補の窓に求める上位の数。同じ表記の道は 1 つにまとめるので、返る件数はこれ以下
    static let listingBest = 20

    private let dictionary: SystemDictionary

    private struct Path {
        enum Kind: UInt8 {
            case start, dictionary, user, unknown
        }

        var cost: Int32
        var start: Int32
        /// 辞書の語の番号、利用者の語の番号、辞書に無い 1 かなの位置
        var word: Int32
        var kind: Kind
        var prevRank: UInt8
        var prevRid: UInt16
    }

    private struct Position {
        var rids: [UInt16] = []
        /// rids と同じ順に、その右 ID で終わる上位の道。コストの小さい順
        var paths: [[Path]] = []
    }

    private struct TableKey: Hashable {
        var kana: String
        var startRid: UInt16
    }

    /// 変換の結果は文脈ごとに覚える。数字の後は数字が違っても始まりの品詞が同じだが、結果の context は求めた数字にする
    private struct ReadingKey: Hashable {
        var kana: String
        var context: JapaneseContext
    }

    /// 採点の前向きの表を読みと始まりの品詞ごとに覚える。読みを 1 かな伸ばすと、前の読みの表に 1 列足すだけで済む。未確定の文字列の寿命だけ持つ
    private var tables: [TableKey: [Position]] = [:]
    private var readings: [ReadingKey: JapaneseReading?] = [:]
    private var userEntries: [UserWord] = []
    private var userWordsByReading: [String: [Int]] = [:]
    private var userSpellings: [String: [String]] = [:]
    private var userCost: Int32 = 0
    /// 語の読みの最長の文字数。格子はこれより前へ遡らない。システム辞書の最長と利用者の語の最長の大きい方
    private var maxReadingChars: Int

    // 前向きの計算の作業域。品詞の数だけの表を使い回す
    private var ridSlot: [Int32]
    private var memoStamp: [Int32]
    private var memo: [[(cost: Int32, rid: UInt16, rank: UInt8)]]
    private var stamp: Int32 = 0

    init(dictionary: SystemDictionary) {
        self.dictionary = dictionary
        maxReadingChars = dictionary.maxReadingChars
        ridSlot = Array(repeating: -1, count: dictionary.posCount)
        memoStamp = Array(repeating: 0, count: dictionary.posCount)
        memo = Array(repeating: [], count: dictionary.posCount)
    }

    /// 文脈の始まりの品詞。Mozc の BOS は文節の始まりで、助詞で始まる文節も安く通すので、文頭は句点の後として読む。
    /// 英語の区間の後は名詞の後（混在文の英語は名詞として働く）、数字の後は数の後として読む
    private func startRid(_ context: JapaneseContext) -> UInt16 {
        switch context {
        case .start: dictionary.periodId
        case .afterWord: dictionary.nounId
        case .afterNumber: dictionary.numberId
        case .afterCaret: preconditionFailure("afterCaret は convert で文頭か前の語に続く形に決めてから渡す")
        }
    }

    private static func startPosition(_ rid: UInt16) -> Position {
        Position(rids: [rid], paths: [[Path(cost: 0, start: -1, word: -1, kind: .start, prevRank: 0, prevRid: 0)]])
    }

    /// コストの小さい順の list に item を入れ、k 個を超えた分を捨てる
    @inline(__always) private static func insert<T>(_ item: T, into list: inout [T], k: Int, cost: (T) -> Int32) {
        if list.count == k, cost(item) >= cost(list[k - 1]) { return }
        var i = list.count
        while i > 0, cost(list[i - 1]) > cost(item) { i -= 1 }
        list.insert(item, at: i)
        if list.count > k { list.removeLast() }
    }

    /// positions に、読みの位置 end で終わる語の道を足す
    private func extend(_ positions: inout [Position], kana: [Character], bytes: [UInt8], offsets: [Int], end: Int, k: Int) {
        var position = Position()
        var touched: [UInt16] = []
        func add(_ rid: UInt16, _ path: Path) {
            var slot = Int(ridSlot[Int(rid)])
            if slot < 0 {
                slot = position.rids.count
                ridSlot[Int(rid)] = Int32(slot)
                position.rids.append(rid)
                position.paths.append([])
                touched.append(rid)
            }
            Self.insert(path, into: &position.paths[slot], k: k) { $0.cost }
        }
        for start in stride(from: end - 1, through: max(0, end - maxReadingChars), by: -1) {
            let from = positions[start]
            if from.rids.isEmpty { continue }
            stamp += 1
            let currentStamp = stamp
            // 同じ左 ID の語は前の道の選び方が同じなので、左 ID ごとに 1 回だけ求める
            func best(into lid: UInt16) -> [(cost: Int32, rid: UInt16, rank: UInt8)] {
                if memoStamp[Int(lid)] == currentStamp { return memo[Int(lid)] }
                var list: [(cost: Int32, rid: UInt16, rank: UInt8)] = []
                list.reserveCapacity(k)
                for (i, rid) in from.rids.enumerated() {
                    let link = dictionary.connection(rid, lid)
                    for (rank, path) in from.paths[i].enumerated() {
                        Self.insert((path.cost + link, rid, UInt8(rank)), into: &list, k: k) { $0.cost }
                    }
                }
                memoStamp[Int(lid)] = currentStamp
                memo[Int(lid)] = list
                return list
            }
            func relax(lid: UInt16, rid: UInt16, cost: Int32, kind: Path.Kind, word: Int32) {
                for prev in best(into: lid) {
                    add(rid, Path(cost: prev.cost + cost, start: Int32(start), word: word, kind: kind, prevRank: prev.rank, prevRid: prev.rid))
                }
            }
            let range = bytes.withUnsafeBufferPointer { dictionary.lookup(UnsafeBufferPointer(rebasing: $0[offsets[start]..<offsets[end]])) }
            for index in range ?? 0..<0 {
                let entry = dictionary.entry(index)
                relax(lid: entry.lid, rid: entry.rid, cost: entry.cost, kind: .dictionary, word: Int32(index))
            }
            for index in userWordsByReading.isEmpty ? [] : userWordsByReading[String(kana[start..<end])] ?? [] {
                relax(lid: dictionary.properNounId, rid: dictionary.properNounId, cost: userCost, kind: .user, word: Int32(index))
            }
            if start == end - 1 {
                relax(lid: 0, rid: 0, cost: Self.unknownCost, kind: .unknown, word: Int32(start))
            }
        }
        for rid in touched { ridSlot[Int(rid)] = -1 }
        positions.append(position)
    }

    private struct Word {
        var start: Int
        var end: Int
        var text: String
        var lid: UInt16
        var rid: UInt16
        var user: Int?
        var unknown = false
    }

    private func backtrack(_ positions: [Position], rid: UInt16, rank: Int, kana: [Character]) -> [Word] {
        var words: [Word] = []
        var end = positions.count - 1
        var rid = rid
        var rank = rank
        while true {
            let position = positions[end]
            guard let slot = position.rids.firstIndex(of: rid) else { preconditionFailure("格子の道が途切れた") }
            let path = position.paths[slot][rank]
            let start = Int(path.start)
            switch path.kind {
            case .start:
                return words.reversed()
            case .dictionary:
                let entry = dictionary.entry(Int(path.word))
                words.append(Word(start: start, end: end, text: dictionary.surface(entry), lid: entry.lid, rid: entry.rid))
            case .user:
                let id = dictionary.properNounId
                words.append(Word(start: start, end: end, text: userEntries[Int(path.word)].word, lid: id, rid: id, user: Int(path.word)))
            case .unknown:
                words.append(Word(start: start, end: end, text: String(kana[start]), lid: 0, rid: 0, unknown: true))
            }
            end = start
            rid = path.prevRid
            rank = Int(path.prevRank)
        }
    }

    /// 区間の終わりの連接。Mozc の連接は EOS への連接がすべて 0 で、活用の途中（ぶっ飛ん）で終わっても減点しない。
    /// 区間の後ろには句点か英語の語（名詞として働く）が続くので、そのうち自然な方の連接を取る
    private func endLink(_ rid: UInt16) -> Int32 {
        min(dictionary.connection(rid, dictionary.periodId), dictionary.connection(rid, dictionary.nounId))
    }

    private func finals(_ positions: [Position], k: Int) -> [(cost: Int32, rid: UInt16, rank: Int)] {
        var list: [(cost: Int32, rid: UInt16, rank: Int)] = []
        let last = positions[positions.count - 1]
        for (i, rid) in last.rids.enumerated() {
            let link = endLink(rid)
            for (rank, path) in last.paths[i].enumerated() {
                Self.insert((path.cost + link, rid, rank), into: &list, k: k) { $0.cost }
            }
        }
        return list
    }

    /// かなと、その UTF-8 のバイト列と、かなの位置ごとのバイトの位置
    private static func layout(_ kana: String) -> (chars: [Character], bytes: [UInt8], offsets: [Int]) {
        let chars = Array(kana)
        var bytes: [UInt8] = []
        var offsets = [0]
        for char in chars {
            bytes.append(contentsOf: String(char).utf8)
            offsets.append(bytes.count)
        }
        return (chars, bytes, offsets)
    }

    /// 1 位の道の前向きの表。覚えた中で最も長い前方一致の読みの表から伸ばす
    private func table(_ chars: [Character], bytes: [UInt8], offsets: [Int], startRid: UInt16) -> [Position] {
        let key = TableKey(kana: String(chars), startRid: startRid)
        if let table = tables[key] { return table }
        var positions = [Self.startPosition(startRid)]
        for length in stride(from: chars.count - 1, to: 0, by: -1) {
            if let found = tables[TableKey(kana: String(chars[..<length]), startRid: startRid)] {
                positions = found
                break
            }
        }
        for end in positions.count...chars.count {
            extend(&positions, kana: chars, bytes: bytes, offsets: offsets, end: end, k: 1)
        }
        tables[key] = positions
        return positions
    }

    /// 1 位の道で、文節の始まりの語から語の境目までの読みが利用者の語の読みに一致する範囲を、その利用者の語にする。左から最長の範囲を取る。
    /// 区切りはコストで決め、その区切りに収まる読みの表記を利用者の辞書登録で決める。
    /// 文節の途中から始まる範囲（彼｜に｜し｜て｜は の にし）は、助詞や活用の並びが登録した読みと重なっただけなので置き換えない
    private func preferringUserWords(_ words: [Word], kana: [Character]) -> [Word] {
        guard !userWordsByReading.isEmpty else { return words }
        var result: [Word] = []
        var i = 0
        while i < words.count {
            let found = i > 0 && !startsClause(words[i], after: words[i - 1]) ? nil : stride(from: words.count, through: i + 1, by: -1).lazy.compactMap { j in
                self.userWordsByReading[String(kana[words[i].start..<words[j - 1].end])].map { (end: j, index: $0[0]) }
            }.first
            guard let found else {
                result.append(words[i])
                i += 1
                continue
            }
            let id = dictionary.properNounId
            result.append(Word(start: words[i].start, end: words[found.end - 1].end, text: userEntries[found.index].word, lid: id, rid: id, user: found.index))
            i = found.end
        }
        return result
    }

    /// segmenter.def で、word が previous の後ろで新しい文節を始めるか。
    /// 辞書に無い 1 かな（ゃ など）の後ろでは切らず、続く語と 1 文節にする（ゃく を ゃ｜く にしない）
    private func startsClause(_ word: Word, after previous: Word) -> Bool {
        !previous.unknown && dictionary.isBoundary(previous.rid, word.lid)
    }

    /// 語の列を、segmenter.def の文節の境目で切り、文節ごとに使った利用者の語を添える
    private func clauses(_ words: [Word], kana: [Character]) -> [ScoredClause] {
        var clauses: [ScoredClause] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let used = current.compactMap { word in
                word.user.map { index in
                    let reading = userEntries[index].reading
                    return UsedUserWord(reading: reading, spellings: userSpellings[reading]!)
                }
            }
            clauses.append(ScoredClause(JapaneseClause(reading: String(kana[first.start..<last.end]), text: current.map(\.text).joined()), userWords: used))
            current = []
        }
        for word in words {
            if let previous = current.last, startsClause(word, after: previous) { flush() }
            current.append(word)
        }
        flush()
        return clauses
    }

    private func reading(_ kana: String, startRid: UInt16, context: JapaneseContext) -> JapaneseReading? {
        let key = ReadingKey(kana: kana, context: context)
        if let cached = readings[key] { return cached }
        guard !kana.isEmpty else { return nil }
        let (chars, bytes, offsets) = Self.layout(kana)
        let positions = table(chars, bytes: bytes, offsets: offsets, startRid: startRid)
        let result = finals(positions, k: 1).first.map { final in
            let words = preferringUserWords(backtrack(positions, rid: final.rid, rank: final.rank, kana: chars), kana: chars)
            return JapaneseReading(text: words.map(\.text).joined(), value: -Double(final.cost) / Self.scale, clauses: clauses(words, kana: chars), context: context)
        }
        readings[key] = result
        return result
    }

    func convert(kana: String, context: JapaneseContext) -> JapaneseReading? {
        guard case .afterCaret = context else { return reading(kana, startRid: startRid(context), context: context) }
        // カーソルの前の文字が文のどこに当たるかは分からないので、文頭と前の語に続く形のうち自然な方で読む
        return [reading(kana, startRid: startRid(.start), context: .start), reading(kana, startRid: startRid(.afterWord), context: .afterWord)]
            .compactMap { $0 }
            .max { $0.value < $1.value }
    }

    func alternatives(kana: String, context: JapaneseContext) -> [String] {
        guard !kana.isEmpty else { return [] }
        let (chars, bytes, offsets) = Self.layout(kana)
        var positions = [Self.startPosition(startRid(context))]
        for end in 1...chars.count {
            extend(&positions, kana: chars, bytes: bytes, offsets: offsets, end: end, k: Self.listingBest)
        }
        var seen: Set<String> = []
        return finals(positions, k: Self.listingBest)
            .map { backtrack(positions, rid: $0.rid, rank: $0.rank, kana: chars).map(\.text).joined() }
            .filter { seen.insert($0).inserted }
    }

    /// 表示も採点と同じ変換にする。表示をモデルで選び直すのは DirectConverter
    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay? {
        convert(kana: kana, context: context).map {
            JapaneseDisplay(text: $0.text, clauses: $0.clauses.map(\.clause), userWords: $0.clauses.flatMap(\.userWords))
        }
    }

    func endComposition() {
        tables = [:]
        readings = [:]
    }

    func replaceUserWords(_ words: [UserWord]) {
        endComposition()
        userEntries = words
        userWordsByReading = Dictionary(grouping: words.indices) { words[$0].reading }
        userSpellings = Dictionary(grouping: words, by: \.reading).mapValues { $0.map(\.word) }
        userCost = Int32((Self.userBaseCost + 500 * log(Double(words.count + 1))).rounded())
        maxReadingChars = max(dictionary.maxReadingChars, words.map(\.reading.count).max() ?? 0)
    }
}
