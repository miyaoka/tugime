#!/bin/bash
# tugime の .app を ~/Library/Input Methods に配置して入力ソースとして登録する。有効化はしない。
# 利用者がシステム設定 → キーボード → 入力ソース → 「+」→ 日本語 で追加する。
#
# 使い方:
#   bash install.sh [<.app>]
#
# 導入する .app は、引数、無ければこのファイルの隣の tugime.app
set -euo pipefail

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "tugime は Apple シリコンの macOS 専用" >&2
    exit 1
fi

# 標準入力から実行すると隣の場所が決まらない。コマンド置換の中で失敗しても外は止まらないので、ここで止める
script="${BASH_SOURCE[0]:?install.sh はファイルとして実行する（bash install.sh）}"
# packslip install が書き出す tugime-install はこのファイルへのシンボリックリンクなので、リンクの置き場ではなく実体の隣を見る
src="${1:-$(dirname "$(realpath "$script")")/tugime.app}"
[[ -d "$src/Contents" ]] || { echo "$src は .app ではない" >&2; exit 1; }
# 置く名前は .app のディレクトリ名にする。渡し方（相対パス・末尾の /.）で変わらないよう、実体の絶対パスに直してから取る
src=$(CDPATH='' cd -- "$src" && pwd -P)
app_dir=${src##*/}
dest="$HOME/Library/Input Methods/$app_dir"
exe="$dest/Contents/MacOS/tugime"

# バンドルを消さずに中身を上書きする。バンドルが無い瞬間に macOS が入力源の一覧を作り直すと登録が消えるため
mkdir -p "$dest"
rsync -a --delete "$src/" "$dest/"
"$lsregister" -f "$dest"
"$exe" --register
# 動いている古い版を止め、終わるのを待ってから新しい版を起動する。起動を macOS に任せると、
# 古い版が終わった直後、macOS がそれを知る前に入力メソッドを求めたアプリが、アプリを起動し直すまで打てなくなることがある
# 実行ファイル名はどの .app も tugime なので、実行ファイルのパスと文字列として一致するものだけを止める
# 代入を挟み、ps の失敗を set -e で止める
found=$(ps -axo pid=,comm= | exe="$exe" awk '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == ENVIRON["exe"]) printf "%s ", pid }')
read -r -a pids <<< "$found"
if (( ${#pids[@]} > 0 )); then
    kill "${pids[@]}"
    for pid in "${pids[@]}"; do
        for _ in {1..50}; do
            kill -0 "$pid" 2>/dev/null || continue 2
            sleep 0.1
        done
        echo "古い版（$pid）が 5 秒以内に止まらない" >&2
        exit 1
    done
    open -g "$dest"
fi
echo "== 配置 $dest"
# システム設定は、ログインし直すまで新しい入力ソースを一覧に出さない（https://developer.apple.com/forums/thread/775526）
echo "初めて入れたときは、ログアウトしてログインし直してから、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 → ${app_dir%.app} で追加する"
