#!/bin/bash
# 精度と打鍵の検証に使う問題ファイルを .eval/problems/ に取得し、SHA-256 を確かめてディレクトリのパスを出す。取得済みで一致すれば取り直さない。
# 版はコミットで固定する。更新するときは revision と sha256 を一緒に変える。置くファイル名は Sources/TugimeEval/ProblemSources.swift の表と同じ。
# 問題はリポジトリに入れない（AJIMEE-Bench は CC-BY-SA 3.0、Mozc は BSD-3-Clause）
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/.eval/problems"

ajimee_revision=401666cd56d1a570c2021798b64b6da4396bfd45
mozc_revision=a069a88d4cb5c011de0f9aebb6c149a1c808d904

# 置くファイル名|URL|SHA-256
files=(
    "ajimee-evaluation_items.json|https://raw.githubusercontent.com/azooKey/AJIMEE-Bench/$ajimee_revision/JWTD_v2/v1/evaluation_items.json|e9eb668fd6aa14b1e26436f429b5550108af0a1dfd443b8cea0bcb3ab3028fca"
    "mozc-oss.tsv|https://raw.githubusercontent.com/google/mozc/$mozc_revision/src/data/test/quality_regression_test/oss.tsv|053a43e72d174da43b351278cadc471abe08cea9fe98829dafe3d152580fcff0"
    "mozc-regression.tsv|https://raw.githubusercontent.com/google/mozc/$mozc_revision/src/data/test/quality_regression_test/regression.tsv|adb5998cdae7e4ba1b746ddef17ac4148f991af5547e178fd50a10788f3a6a55"
)

matches() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]
}

mkdir -p "$dir"
for entry in "${files[@]}"; do
    IFS='|' read -r name url sha256 <<<"$entry"
    file="$dir/$name"
    if matches "$file" "$sha256"; then
        continue
    fi
    echo "== 取得 $url" >&2
    curl -fL --retry 3 --max-time 120 -o "$file.part" "$url"
    matches "$file.part" "$sha256" || { echo "$url の SHA-256 が $sha256 と一致しない" >&2; exit 1; }
    mv "$file.part" "$file"
done
echo "$dir"
