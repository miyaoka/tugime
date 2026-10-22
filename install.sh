#!/bin/bash
# tugime.app を ~/Library/Input Methods に配置して入力ソースとして登録する。有効化はしない。
# 利用者がシステム設定 → キーボード → 入力ソース → 「+」→ 日本語 で追加する。
#
# 使い方:
#   bash install.sh [tugime.app]
#   curl -fsSL https://raw.githubusercontent.com/miyaoka/tugime/main/install.sh | bash
#
# 導入する tugime.app は、引数、このファイルの隣の tugime.app、GitHub の最新のリリース、の順で決める。
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
# 配布版の tugime.app と、ソースから組み立てた tugime Local.app は、別の名前で隣に置く
dest="$HOME/Library/Input Methods/$(basename "$src")"
exe="$dest/Contents/MacOS/tugime"

# バンドルを消さずに中身を上書きする。バンドルが無い瞬間に macOS が入力源の一覧を作り直すと登録が消えるため
mkdir -p "$dest"
rsync -a --delete "$src/" "$dest/"
# ブラウザで取得した配布物から入れたときの隔離属性を外す。ad-hoc 署名なので、付いたままだと起動できない
xattr -dr com.apple.quarantine "$dest"
"$lsregister" -f "$dest"
"$exe" --register
# 動いている古い版を止める。次に入力源が選ばれたときに新しい版が起動する
# 実行ファイル名はどの .app も tugime なので、パスで照合して隣の .app のプロセスを止めない
# pkill は該当するプロセスが無いと 1 を返す。それ以外の失敗は止める
pkill -f "^$exe\$" || [[ $? -eq 1 ]]
echo "== 配置 $dest"
echo "初めて入れたときは、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 → $(basename "$dest" .app) (日本語) で追加する"
