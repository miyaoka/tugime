#!/bin/bash
# 入力メソッドが使うモデル（genmai-310M の q8_0）を .zenz/ に用意し、SHA-256 を確かめてパスを出す。用意済みで一致すれば作り直さない。
# 無いか一致しなければ、Hugging Face の重みを scripts/convert-hf-to-gguf.sh で変換し、作った GGUF の SHA-256 を確かめる。
# 版は Hugging Face のコミットで固定する。更新するときは commit・sha256 と、App/Notices/genmai-310M.txt の版とコミットを一緒に変える
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
repo=subdiox/genmai-310M
# v0.1.1
commit=c348c1018f3b02c15399c02f58a379add4cc1408
sha256=fa951e50aa42880d08ec24579e089ff7bb7c8057cf0a11b48d18b77b0468986b
name=genmai-310M-q8_0
model="$root/.zenz/$name.gguf"

matches() {
    [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$sha256" ]]
}

if ! matches "$model"; then
    "$root/scripts/convert-hf-to-gguf.sh" "$repo" "$commit" q8_0 "$name" >&2
    matches "$model" || { echo "$repo $commit から変換した $model の SHA-256 が $sha256 と一致しない" >&2; exit 1; }
fi
echo "$model"
