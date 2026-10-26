#!/bin/bash
# README と docs の図の字形を取り出すフォント（LINE Seed JP、SIL Open Font License 1.1）を
# .fonts/ に取得し、SHA-256 を確かめてディレクトリを出す。取得済みで一致すれば取り直さない。版は google/fonts のコミットで固定する
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
revision=e7db6ca603fd4862010383ff17ffd6cc4ffac1c0
dir="$root/.fonts"
fonts=(
    "ofl/lineseedjp/LINESeedJP-Bold.ttf 67aec2dc10b3ad210d6f7d53b33bbfea42ea28e32fa3834624eee699a638d5ff"
    "ofl/lineseedjp/LINESeedJP-Regular.ttf 04a6c0077ddb8ba5af3638bd76b4600708dde7b38df047b40fbe6f3af358d3c3"
)

matches() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]
}

mkdir -p "$dir"
for entry in "${fonts[@]}"; do
    read -r path sha256 <<<"$entry"
    file="$dir/$(basename "$path")"
    matches "$file" "$sha256" && continue
    url="https://raw.githubusercontent.com/google/fonts/$revision/$path"
    echo "== 取得 $url" >&2
    curl -fL --retry 3 --max-time 120 -o "$file.part" "$url"
    matches "$file.part" "$sha256" || { echo "$url の SHA-256 が $sha256 と一致しない" >&2; exit 1; }
    mv "$file.part" "$file"
done
echo "$dir"
