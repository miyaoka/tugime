#!/bin/bash
# dist/tugime.app と install.sh を配布用の tar.gz にまとめる。先に TUGIME_BUILD_CHANNEL=stable scripts/build-app.sh を実行する。
# ルートに 2 項目を置く。ルートがディレクトリ 1 個だけの tar は、mise が strip_components=1 を当てて .app を崩すため
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dist="$root/dist"
archive="$dist/tugime-macos-arm64.tar.gz"

test -d "$dist/tugime.app" || { echo "$dist/tugime.app が無い。先に TUGIME_BUILD_CHANNEL=stable scripts/build-app.sh を実行する" >&2; exit 1; }
stage="$(mktemp -d)"
ditto "$dist/tugime.app" "$stage/tugime.app"
cp "$root/install.sh" "$stage/install.sh"
tar -C "$stage" -czf "$archive" tugime.app install.sh
echo "== 作成 $archive"
