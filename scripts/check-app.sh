#!/bin/bash
# 引数の組み立てた .app について、組み立てたディレクトリ（.build）に頼らずに綴りの表・語表・辞書・表示の変換のモデル・llama.framework を
# 読めることと、実行ファイルと llama.framework が Apple Silicon 向け（arm64）だけを含むことを確かめる。
# SwiftPM の生成するリソースの探し方はビルドの仕組みで違い、組み立てたマシンの絶対パスを探すものがあるので、.build を退避して実行する
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app=$(cd "$1" && pwd)
aside=$(mktemp -d)

mv "$root/.build" "$aside/"
trap 'mv "$aside/.build" "$root/" && rmdir "$aside"' EXIT
"$app/Contents/MacOS/tugime" --check

# 対象は Apple Silicon だけなので、実行ファイルと同梱のフレームワークは arm64 だけを含む
for binary in "$app/Contents/MacOS/tugime" "$app/Contents/Frameworks/llama.framework/llama"; do
    archs=$(lipo -archs "$binary")
    [[ "$archs" == "arm64" ]] || { echo "対象が arm64 だけではない: $binary $archs" >&2; exit 1; }
    echo "対象 $archs $(basename "$binary")"
done
