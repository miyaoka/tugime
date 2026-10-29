import Foundation

/// かなを変換した最良の結果と、その言語モデル上の評価値
public struct JapaneseReading: Sendable, Equatable {
    /// 最良の区切りの表記。区切りに収まる読みには、利用者の語の表記が入ることがある
    public var text: String
    /// 区切りを決めた変換エンジンの評価値。大きいほど自然
    public var value: Double
    /// text を文節に分けたもの。読みを繋ぐと変換したかなに、表記を繋ぐと text になる
    public var clauses: [ScoredClause]
    /// この変換を読んだ文脈。afterCaret は文頭か前の語に続く形のどちらかに決まり、それ以外は求めたとおり
    public var context: JapaneseContext

    public init(text: String, value: Double, clauses: [ScoredClause], context: JapaneseContext) {
        self.text = text
        self.value = value
        self.clauses = clauses
        self.context = context
    }
}

/// 表示の変換の結果。評価値を持たないので、区切りの採点には使えない
public struct JapaneseDisplay: Sendable, Equatable {
    public var text: String
    /// text を文節に分けたもの。読みを繋ぐと変換したかなに、表記を繋ぐと text になる
    public var clauses: [JapaneseClause]
    /// text を作った変換が使った利用者の語
    public var userWords: [UsedUserWord]

    public init(text: String, clauses: [JapaneseClause], userWords: [UsedUserWord] = []) {
        self.text = text
        self.clauses = clauses
        self.userWords = userWords
    }

    /// text のかなが、変換した読みのかなと同じ順に並ぶか（ReadingAlignment で対応づくか）。漢字の中の読みは見ない。
    /// 利用者の語の表記は、利用者が決めた読みの書き方なので、text のままで合わなければ、表記をその語の読みに置き換えて照らす
    /// （よろしく → よろしくお願いします の お願いします を読み違いにしない）。置き換えは表記が現れるすべての位置に及び、
    /// 別の読みの語の一部（点く の 点）も変えるので、text のままで合う表示には当てない
    public var matchesReading: Bool {
        let reading = clauses.map(\.reading).joined()
        guard ReadingAlignment(text: text, reading: reading) == nil else { return true }
        return ReadingAlignment(text: readingUserSpellings, reading: reading) != nil
    }

    /// text を前から 1 度だけ読み、各位置で最も長く一致する利用者の語の表記をその語の読みにしたもの。置き換えた読みを、ほかの語の表記として読み直さない
    private var readingUserSpellings: String {
        let spellings = userWords.flatMap { word in word.spellings.map { (spelling: $0, reading: word.reading) } }.sorted { $0.spelling.count > $1.spelling.count }
        var read = ""
        var rest = text[...]
        while !rest.isEmpty {
            if let match = spellings.first(where: { rest.hasPrefix($0.spelling) }) {
                read += match.reading
                rest = rest.dropFirst(match.spelling.count)
            } else {
                read.append(rest.removeFirst())
            }
        }
        return read
    }
}

/// 変換エンジンが語の列に使った利用者の語
public struct UsedUserWord: Sendable, Equatable {
    /// 利用者が登録した読み
    public var reading: String
    /// この読みに利用者が登録した表記。使った表記を含む
    public var spellings: [String]

    public init(reading: String, spellings: [String]) {
        self.reading = reading
        self.spellings = spellings
    }
}

/// 変換結果の 1 文節
public struct JapaneseClause: Sendable, Equatable {
    public var reading: String
    public var text: String

    public init(reading: String, text: String) {
        self.reading = reading
        self.text = text
    }
}

/// 採点の変換の 1 文節と、変換エンジンがその文節に使った利用者の語。
/// 利用者の語を使ったかは採点の変換だけが知るので、表示の文節（JapaneseClause）には持たせない
public struct ScoredClause: Sendable, Equatable {
    public var clause: JapaneseClause
    /// この文節の読みの中で、変換エンジンが語の列に使った利用者の語
    public var userWords: [UsedUserWord]

    public init(_ clause: JapaneseClause, userWords: [UsedUserWord] = []) {
        self.clause = clause
        self.userWords = userWords
    }
}

/// 日本語区間をどの位置にあるものとして評価するか
public enum JapaneseContext: Sendable, Hashable {
    /// 文頭から始まる文として評価する
    case start
    /// 前の語に続く形として評価する。英語区間の直後（混在文の英語は名詞として働く）
    case afterWord
    /// 入力欄のカーソルの前にある文字に続けて打ち始めたときの形。前の文字が文のどこに当たるかは分からないので、
    /// 前の語に続く形と新しく始まる形のうち自然な方で評価する。convert だけが受け取り、どちらの形で読んだかを結果の context で返す
    case afterCaret
    /// 数字に続く形として評価する。数字は変換エンジンがそのまま扱えるので、助数詞（円・回・個）として読ませる
    case afterNumber(String)
}

/// 日本語区間の後ろに続くもの。区間の終わりのつながりは、実際に後ろにあるもので決める（PRINCIPLES.md）
public enum JapaneseEnding: Sendable, Hashable {
    /// 後ろにまだ何も打たれていない（入力の末尾）か、後ろの日本語区間と後でまとめて変換し直す切れ目。つながりを足さない
    case open
    /// 後ろに英語区間か利用者の語の区間が続く。その語の後に続く形（afterWord）と同じく名詞として読む
    case beforeWord
    /// 後ろに句読点か記号の打鍵が続く。値は日本語の記号（、。「 など）
    case beforeMark(String)
}

public protocol JapaneseConverting: AnyObject {
    /// 区切りの採点に使う最良の変換
    func convert(kana: String, context: JapaneseContext, ending: JapaneseEnding) -> JapaneseReading?
    /// 候補の窓に並べる変換結果。評価値の高い順で、重複は除く。件数は変換エンジンが決める。context に afterCaret は渡さず、convert が返した context を渡す
    func alternatives(kana: String, context: JapaneseContext) -> [String]
    /// 区切りが決まった区間を表示するための変換。採点のように何百回も呼ばないので、重くて質の高い変換を使ってよい。
    /// left は入力欄のカーソルより前の文字列に、入力の中でこの区間より前に表示している文字列をつないだもの。context は afterCaret を渡さず、convert が返した context を渡す。
    /// convert が変換を返すかなと文脈には、必ず変換を返す
    func display(kana: String, context: JapaneseContext, left: String) -> JapaneseDisplay?
    /// requests のそれぞれの display。requests と同じ順に返す。まとめて渡したものは同時に計算してよい
    func displays(_ requests: [DisplayRequest]) -> [JapaneseDisplay?]
    /// left に続く texts のそれぞれの、文としての確からしさ（対数確率）。texts と同じ順に返す。日英の区切りの候補を表示にした文どうしを比べるのに使う。
    /// 文を評価するモデルを持たない変換器は nil を返し、区切りは採点の点だけで決まる
    func naturalness(texts: [String], left: String) -> [Double]?
    /// 未確定の文字列を確定・取り消ししたときに、その文字列のために覚えたものを捨てる
    func endComposition()
    /// 利用者の語を words に丸ごと置き換える。endComposition で捨てるものも捨てるので、呼ぶと未確定の文字列が終わる。
    /// 作った直後の変換器は利用者の語を持たない
    func replaceUserWords(_ words: [UserWord])
}

extension JapaneseConverting {
    /// まとめて計算する仕組みを持たない変換器は、1 つずつ display にする
    public func displays(_ requests: [DisplayRequest]) -> [JapaneseDisplay?] {
        requests.map { display(kana: $0.kana, context: $0.context, left: $0.left) }
    }
}

/// display に渡す 1 つの要求
public struct DisplayRequest: Sendable, Hashable {
    public var kana: String
    public var context: JapaneseContext
    public var left: String

    public init(kana: String, context: JapaneseContext, left: String) {
        self.kana = kana
        self.context = context
        self.left = left
    }
}
