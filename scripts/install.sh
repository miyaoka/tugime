#!/bin/bash
# dist/tugime.app を ~/Library/Input Methods に配置して登録する。
# バンドルを消さずに中身を上書きする。バンドルが無い瞬間に macOS が入力源の一覧を作り直すと登録が消えるため。
# 有効化はしない。利用者がシステム設定の「+」で追加する。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/dist/tugime.app"
dest="$HOME/Library/Input Methods/tugime.app"

test -d "$src" || { echo "$src が無い。先に scripts/build-app.sh を実行する" >&2; exit 1; }
mkdir -p "$dest"
rsync -a --delete "$src/" "$dest/"
"$dest/Contents/MacOS/tugime" --register
# 動いている古い版を止める。次に入力源が選ばれたときに新しい版が起動する
pkill -x tugime || true
echo "== 配置 $dest"
