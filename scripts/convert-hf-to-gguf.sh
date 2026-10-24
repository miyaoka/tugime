#!/bin/bash
# Hugging Face の safetensors（GPT-2 系）を、azooKey が同梱する llama.cpp が読める GGUF に変換してパスを出す。
# 使い方: scripts/convert-hf-to-gguf.sh <Hugging Face のリポジトリ> <コミット> <量子化> <出力名>
#   例: scripts/convert-hf-to-gguf.sh subdiox/genmai-310M 5bbde09cfdf5c25cceebb0db8edb2184559a2fc0 q8_0 genmai-310M-q8_0
# 量子化は convert_hf_to_gguf.py の --outtype（f32 / f16 / bf16 / q8_0）。出力は .zenz/<出力名>.gguf。
# 変換が効いたかはこのスクリプトでは判定しない。tugime-eval accuracy --method direct:<出力> で、基準と同じ出力の件数と正解数を見る（全件が基準と同じなら終了コード 1）。
# zenzai: の方式は azooKey の計算の設定で動くので、そこで壊れるモデル（genmai-310M）では、正しい GGUF でも効いていないように見える。
# 元のファイルは .eval/hf/ に、変換の道具は .eval/llama.cpp に置き、取得済みなら取り直さない
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# 取得と変換の Python は scripts/convert-env の uv.lock で固定した環境で動かす。環境は .eval/ に作る
export UV_PROJECT_ENVIRONMENT="$root/.eval/convert-env"
uv_run=(uv run --project "$root/scripts/convert-env" --locked)
# azooKey の llama.cpp のフォークで、azooKey が同梱する llama.cpp と同じ版。前処理の名前の表がこの版のもの
llama_repo=https://github.com/azooKey/llama.cpp
llama_commit=10131b23ee0dbd9d03dfc618cec9fe3402919277 # タグ b4846
# Zenzai が読む前処理の名前。convert_hf_to_gguf.py がトークナイザーから判別した結果がこれでなければ止める
pre_tokenizer=gpt2-small-japanese-char
# 設定とトークナイザーのファイル（リポジトリの直下のもの）。トークナイザーの形（tokenizer.json か vocab.json と merges.txt か）は
# モデルごとに違うので、在るものを全部取る
meta_files=(config.json generation_config.json tokenizer.json tokenizer_config.json special_tokens_map.json vocab.json merges.txt model.safetensors.index.json)
# 重みは transformers と同じく、分割の目録があればそこに書かれたファイル、無ければ model.safetensors だけを取る。
# 変換はディレクトリの safetensors をすべて読むので、IME 用の量子化版など別の重みを並べて置かない

if [[ $# -ne 4 ]]; then
    sed -n '2,6p' "$0" >&2
    exit 2
fi
repo=$1
commit=$2
outtype=$3
name=$4
# タグとブランチは後から動くので、コミットだけを受け付ける
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "コミットは 40 桁の 16 進で渡す: $commit" >&2
    exit 2
fi

# 変換はディレクトリの名前から general.name などを作るので、最後をリポジトリの名前にする
source_dir="$root/.eval/hf/$commit/$repo"
mkdir -p "$source_dir"
# 取得は Hugging Face の公式 CLI。--local-dir に取得済みの記録を置き、取得済みなら取り直さない
# --include は 1 つの後ろにパターンを並べる。繰り返すと最後の 1 つだけが効く
hf_download=("${uv_run[@]}" hf download "$repo" --revision "$commit" --local-dir "$source_dir" --quiet --include)
echo "== 取得 $repo $commit の設定とトークナイザー" >&2
"${hf_download[@]}" "${meta_files[@]}" >&2
if [[ ! -f "$source_dir/config.json" ]]; then
    echo "$repo $commit に config.json が無い" >&2
    exit 1
fi

weights=(model.safetensors)
index="$source_dir/model.safetensors.index.json"
if [[ -f "$index" ]]; then
    weights=()
    names="$source_dir/.weights"
    "${uv_run[@]}" python -I -c '
import json, sys
for name in sorted(set(json.load(open(sys.argv[1]))["weight_map"].values())):
    print(name)
' "$index" > "$names"
    while IFS= read -r line; do weights+=("$line"); done < "$names"
fi
echo "== 取得 $repo $commit の重み ${weights[*]}" >&2
"${hf_download[@]}" "${weights[@]}" >&2
# 重みの組に入らない safetensors が置かれていれば止める（変換がそれも読むため）
for file in "$source_dir"/*.safetensors; do
    if ! printf "%s\n" "${weights[@]}" | grep -qx "$(basename "$file")"; then
        echo "重みの組に入らない $file がある。消してからやり直す" >&2
        exit 1
    fi
done

llama="$root/.eval/llama.cpp"
if [[ "$(git -C "$llama" rev-parse HEAD 2>/dev/null)" != "$llama_commit" ]]; then
    echo "== 取得 $llama_repo $llama_commit" >&2
    rm -rf "$llama"
    git init -q "$llama"
    git -C "$llama" fetch -q --depth 1 "$llama_repo" "$llama_commit"
    git -C "$llama" checkout -q FETCH_HEAD
fi

out="$root/.zenz/$name.gguf"
mkdir -p "$(dirname "$out")"
echo "== 変換 $repo $commit → ${out}（${outtype}）" >&2
"${uv_run[@]}" python "$llama/convert_hf_to_gguf.py" "$source_dir" --outtype "$outtype" --outfile "$out.part" >&2

# 書き出した GGUF の前処理の名前を、同じ版の gguf-py で読んで確かめる
"${uv_run[@]}" python - "$llama/gguf-py" "$out.part" "$pre_tokenizer" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from gguf import GGUFReader

field = GGUFReader(sys.argv[2]).fields["tokenizer.ggml.pre"]
pre = bytes(field.parts[field.data[0]]).decode()
if pre != sys.argv[3]:
    sys.exit(f"tokenizer.ggml.pre が {sys.argv[3]} でなく {pre}")
EOF
mv "$out.part" "$out"
echo "$out"
