#!/bin/bash
# Zenzai のモデル（zenz-v3.2-small の Q5_K_M）を .zenz/ に取得し、SHA-256 を確かめてパスを出す。取得済みで一致すれば取り直さない。
# 版は Hugging Face のコミットで固定する。更新するときは revision と sha256 を一緒に変える
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
revision=c67e03e07d215c869f591b274c1631170d3e11fe
sha256=29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db673
url="https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/$revision/ggml-model-Q5_K_M.gguf"
model="$root/.zenz/ggml-model-Q5_K_M.gguf"

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
