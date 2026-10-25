import Foundation

/// 精度を測る 1 問。どの出典の問題も、読みを左の文脈の後ろで打って確定する文字列を 1 つ得て、それを判定にかける形にそろえる。
/// 出典ごとの違いは読み込みで吸収し、打つ側と集計は出典を知らない
public struct Problem: Sendable, Codable, Equatable {
    /// `<集まり>:<番号>`。版を固定した問題ファイルからは常に同じ値になる。比較はこれで問題を突き合わせる
    public var id: String
    /// 集計の単位。ajimee / mozc-oss / mozc-regression
    public var set: String
    /// 打つ読み。ひらがなと、句読点・記号・英字・数字など出典が読みに含めた文字。カタカナで渡された問題は読み込みでひらがなにする
    public var kana: String
    /// 入力欄でこの問題の前にある文字列。無ければ空
    public var left: String
    public var check: Check
}

/// 出力の判定。出典の判定の言葉をここに写し、出典に無い判定は作らない
public enum Check: Sendable, Codable, Equatable {
    /// 許容解のどれかと完全一致（AJIMEE-Bench の expected_output）
    case oneOf([String])
    /// 完全一致（Mozc の Conversion Expected。先頭の候補を繋いだ文字列 = 打って確定する文字列）
    case exact(String)
    /// 含む（Mozc の Conversion Match）
    case contains(String)
    /// 含まない（Mozc の Conversion Not Match）
    case excludes(String)

    /// 集計で判定ごとにまとめるための名前
    public var kind: String {
        switch self {
        case .oneOf: "oneOf"
        case .exact: "exact"
        case .contains: "contains"
        case .excludes: "excludes"
        }
    }

    public func passes(_ output: String) -> Bool {
        switch self {
        case .oneOf(let answers): answers.contains(output)
        case .exact(let value): output == value
        case .contains(let value): output.contains(value)
        case .excludes(let value): !output.contains(value)
        }
    }
}
