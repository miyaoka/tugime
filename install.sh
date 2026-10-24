#!/bin/bash
# tugime の .app を ~/Library/Input Methods に配置して入力ソースとして登録する。有効化はしない。
# 利用者がシステム設定 → キーボード → 入力ソース → 「+」→ 日本語 で追加する。
#
# 使い方:
#   bash install.sh [<.app>]
#
# 導入する .app は、引数、無ければこのファイルの隣の tugime.app。取得はしない。
# 配布物の出自は、展開する前に利用者か mise が確かめる
set -euo pipefail

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "tugime は Apple シリコンの macOS 専用" >&2
    exit 1
fi

src="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tugime.app}"
[[ -d "$src/Contents" ]] || { echo "$src は .app ではない" >&2; exit 1; }
# 置く名前は .app のディレクトリ名にする。渡し方（相対パス・末尾の /.）で変わらないよう、実体の絶対パスに直してから取る
src=$(CDPATH='' cd -- "$src" && pwd -P)
app_dir=${src##*/}
dest="$HOME/Library/Input Methods/$app_dir"
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
echo "初めて入れたときは、ログアウトしてログインし直してから、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 → ${app_dir%.app} (日本語) で追加する"
