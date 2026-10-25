/// 打ち始めの前の文字列を決める。入力欄が前の文字列を返さないアプリ（Ghostty など）では、tugime が続けて確定した文字列を代わりにする
public struct LeadingContext: Sendable {
    /// tugime が続けて確定した文字列
    private var committed = Segmenter.Leading.start
    /// 入力欄が、tugime の確定した文字列を前の文字列として返したことがあるか。返す入力欄で前に何も無いのは、
    /// カーソルを先頭や別の欄へ動かしたときなので、確定した文字列を使わない
    private var fieldShowsCommits = false

    public init() {}

    /// 入力欄から読んだ前の文字列 field から、打ち始めの前の文字列を決める
    public mutating func leading(field: Segmenter.Leading) -> Segmenter.Leading {
        if field.text.isEmpty {
            return fieldShowsCommits ? field : committed
        }
        // どちらもカーソルの前の文字列の末尾なので、入力欄が確定した文字列を返していれば短い方が長い方の末尾になる
        if !committed.text.isEmpty, field.text.hasSuffix(committed.text) || committed.text.hasSuffix(field.text) {
            fieldShowsCommits = true
        }
        return field
    }

    /// tugime が text を確定した。長さは入力欄から読むときと同じ上限までにする
    public mutating func didCommit(_ text: String) {
        committed = Segmenter.Leading(field: committed.text + text)
    }

    /// 入力欄に tugime を通らない変更が入りうるとき（キーをアプリに渡す、フォーカスが外れる）に呼ぶ。確定した文字列は前の文字列でなくなる
    public mutating func forgetCommits() {
        committed = .start
    }
}
