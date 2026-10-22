#!/bin/bash
# tugime の .app を ~/Library/Input Methods に配置して入力ソースとして登録する。有効化はしない。
# 利用者がシステム設定 → キーボード → 入力ソース → 「+」→ 日本語 で追加する。
#
# 使い方:
#   bash install.sh [<.app>]
#   curl -fsSL https://raw.githubusercontent.com/miyaoka/tugime/main/install.sh | bash
#
# 導入する .app は、引数、このファイルの隣の tugime.app、GitHub の最新のリリース、の順で決める。
set -euo pipefail

repo="miyaoka/tugime"
asset="tugime-macos-arm64.tar.gz"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "tugime は Apple シリコンの macOS 専用" >&2
    exit 1
fi

script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

download_latest() {
    local work
    work="$(mktemp -d)"
    local url="https://github.com/$repo/releases/latest/download/$asset"
    echo "== 取得 $url" >&2
    curl -fsSL "$url" | tar -xzf - -C "$work"
    echo "$work/tugime.app"
}

if [[ $# -ge 1 ]]; then
    src="$1"
elif [[ -n "$script_dir" && -d "$script_dir/tugime.app" ]]; then
    src="$script_dir/tugime.app"
else
    src="$(download_latest)"
fi
[[ -d "$src/Contents" ]] || { echo "$src は .app ではない" >&2; exit 1; }
# 置く名前は組み立てたときに焼いた名前から決める。引数のパスの名前は、渡し方で変わる
name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$src/Contents/Info.plist")
# 名前をパスの 1 要素に限り、置く先を ~/Library/Input Methods の直下から出さない
case "$name" in
    "" | */* | .*)
        echo "$src の CFBundleName は配置先の名前に使えない: '$name'" >&2
        exit 1
        ;;
esac
dest="$HOME/Library/Input Methods/$name.app"
exe="$dest/Contents/MacOS/tugime"

# バンドルを消さずに中身を上書きする。バンドルが無い瞬間に macOS が入力源の一覧を作り直すと登録が消えるため
mkdir -p "$dest"
rsync -a --delete "$src/" "$dest/"
# ブラウザで取得した配布物から入れたときの隔離属性を外す。ad-hoc 署名なので、付いたままだと起動できない
xattr -dr com.apple.quarantine "$dest"
"$lsregister" -f "$dest"
"$exe" --register
# 動いている古い版を止める。次に入力源が選ばれたときに新しい版が起動する
# 実行ファイル名はどの .app も tugime なので、実行ファイルのパスと文字列として一致するものだけを止める
# 代入を挟み、ps の失敗を set -e で止める
found=$(ps -axo pid=,comm= | exe="$exe" awk '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == ENVIRON["exe"]) printf "%s ", pid }')
read -r -a pids <<< "$found"
(( ${#pids[@]} == 0 )) || kill "${pids[@]}"
echo "== 配置 $dest"
# システム設定は、ログインし直すまで新しい入力ソースを一覧に出さない（https://developer.apple.com/forums/thread/775526）
echo "初めて入れたときは、ログアウトしてログインし直してから、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 → $name (日本語) で追加する"
