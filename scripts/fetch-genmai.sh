#!/bin/bash
# 入力メソッドが使うモデル（genmai-310M の q8_0）を .zenz/ に取得し、SHA-256 を確かめてパスを出す。取得済みで一致すれば取り直さない。
# 版は Hugging Face のコミットで固定する。更新するときは scripts/convert-hf-to-gguf.sh で変換した GGUF を miyaoka/genmai-310M-GGUF に上げ、
# revision・sha256 と、App/Notices/genmai-310M.txt の版とコミットを一緒に変える
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
revision=d79b9b71c2ff9a6debdb8d2f4670729a2043b5cb
sha256=fa951e50aa42880d08ec24579e089ff7bb7c8057cf0a11b48d18b77b0468986b
url="https://huggingface.co/miyaoka/genmai-310M-GGUF/resolve/$revision/genmai-310M-q8_0.gguf"
model="$root/.zenz/genmai-310M-q8_0.gguf"

matches() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$sha256" ]]
}

if ! matches "$model"; then
    mkdir -p "$(dirname "$model")"
    echo "== 取得 $url" >&2
    curl -fL --retry 3 --max-time 600 -o "$model.part" "$url"
    matches "$model.part" || { echo "$url の SHA-256 が $sha256 と一致しない" >&2; exit 1; }
    mv "$model.part" "$model"
fi
echo "$model"
