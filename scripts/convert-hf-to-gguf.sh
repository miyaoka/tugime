#!/bin/bash
# Hugging Face の safetensors（GPT-2 系）を、azooKey の Zenzai が読める GGUF に変換してパスを出す。
# 使い方: scripts/convert-hf-to-gguf.sh <Hugging Face のリポジトリ> <コミット> <量子化> <出力名>
#   例: scripts/convert-hf-to-gguf.sh subdiox/genmai-310M 5bbde09cfdf5c25cceebb0db8edb2184559a2fc0 q8_0 genmai-310M-q8_0
# 量子化は convert_hf_to_gguf.py の --outtype（f32 / f16 / bf16 / q8_0）。出力は .zenz/<出力名>.gguf。
# 変換が効いたかはこのスクリプトでは判定しない。tugime-eval accuracy --method zenzai:<出力> で、基準と同じ出力の件数と正解数を見る（全件が基準と同じなら終了コード 1）。
# 元のファイルは .eval/hf/ に、変換の道具は .eval/llama.cpp に置き、取得済みなら取り直さない
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# azooKey の llama.cpp のフォークで、azooKey が同梱する llama.cpp と同じ版。前処理の名前の表がこの版のもの
llama_repo=https://github.com/azooKey/llama.cpp
llama_commit=10131b23ee0dbd9d03dfc618cec9fe3402919277 # タグ b4846
# Zenzai が読む前処理の名前。convert_hf_to_gguf.py がトークナイザーから判別した結果がこれでなければ止める
pre_tokenizer=gpt2-small-japanese-char
# 変換に読むファイル
hf_files=(config.json tokenizer.json tokenizer_config.json model.safetensors)

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
for file in "${hf_files[@]}"; do
    [[ -f "$source_dir/$file" ]] && continue
    url="https://huggingface.co/$repo/resolve/$commit/$file"
    echo "== 取得 $url" >&2
    curl -fL --retry 3 --max-time 1800 -o "$source_dir/$file.part" "$url"
    mv "$source_dir/$file.part" "$source_dir/$file"
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
# 依存は llama.cpp のこの版の変換が動いた組み合わせ
uv_run=(uv run --no-project --python 3.11
    --with torch==2.2.2 --with numpy==1.26.4 --with sentencepiece==0.2.0
    --with "transformers>=4.45.1,<5" --with "protobuf<5")
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
