#!/bin/bash
# 組み立てた tugime.app が、組み立てたディレクトリ（.build）に頼らずに綴りの表・語表・辞書を読めるかを確かめる。
# SwiftPM の生成するリソースの探し方はビルドの仕組みで違い、組み立てたマシンの絶対パスを探すものがあるので、.build を退避して実行する
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/dist/tugime.app"
aside=$(mktemp -d)

mv "$root/.build" "$aside/"
trap 'mv "$aside/.build" "$root/" && rmdir "$aside"' EXIT
"$app/Contents/MacOS/tugime" --check
