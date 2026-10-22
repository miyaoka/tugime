#!/bin/bash
# 組み立てた tugime.app について、組み立てたディレクトリ（.build）に頼らずに綴りの表・語表・辞書を読めることと、
# 実行ファイルが Apple Silicon 向け（arm64）だけを含むことを確かめる。
# SwiftPM の生成するリソースの探し方はビルドの仕組みで違い、組み立てたマシンの絶対パスを探すものがあるので、.build を退避して実行する
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/tugime.app"
aside=$(mktemp -d)

mv "$root/.build" "$aside/"
trap 'mv "$aside/.build" "$root/" && rmdir "$aside"' EXIT
"$app/Contents/MacOS/tugime" --check

# 対象は Apple Silicon だけなので、実行ファイルは arm64 だけを含む
archs=$(lipo -archs "$app/Contents/MacOS/tugime")
[[ "$archs" == "arm64" ]] || { echo "実行ファイルの対象が arm64 だけではない: $archs" >&2; exit 1; }
echo "対象 $archs"
