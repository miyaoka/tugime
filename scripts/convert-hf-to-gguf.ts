// Hugging Face の safetensors（GPT-2 系）を、tugime が載せる llama.cpp が読める GGUF に変換してパスを出す。使い方は USAGE。
// 変換が効いたかはこのスクリプトでは判定しない。tugime-eval accuracy --method direct:<出力> で、基準と同じ出力の件数と正解数を見る（全件が基準と同じなら終了コード 1）。
// 元のファイルは .eval/hf/ に、変換の道具は .eval/llama.cpp に置き、取得済みなら取り直さない
import { $ } from "bun";
import { mkdir, readdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { root } from "./lib/root";

const USAGE = `使い方: bun scripts/convert-hf-to-gguf.ts <Hugging Face のリポジトリ> <コミット> <量子化> <出力名>
  例: bun scripts/convert-hf-to-gguf.ts subdiox/genmai-310M 3d52f4fe739c42e00801cc5646cd5bc79913dc4e q8_0 genmai-310M-q8_0
量子化は convert_hf_to_gguf.py の --outtype（f32 / f16 / bf16 / q8_0）。出力は .zenz/<出力名>.gguf。`;

// 取得と変換の Python は scripts/convert-env の uv.lock で固定した環境で動かす。環境は .eval/ に作る
$.env({
  ...process.env,
  UV_PROJECT_ENVIRONMENT: join(root, ".eval/convert-env"),
});
const uvRun = [
  "uv",
  "run",
  "--project",
  join(root, "scripts/convert-env"),
  "--locked",
];
// tugime が binaryTarget に載せる llama.cpp と同じ版
const LLAMA_REPO = "https://github.com/ggml-org/llama.cpp";
const LLAMA_COMMIT = "c6fb3b5be2209f6c12339833198190f6f6829581"; // タグ b11899
// 変換はトークナイザーで決まった文字列を区切った結果のハッシュから前処理の名前を決め、表に無いハッシュでは止まる。
// zenz 形式のモデルのトークナイザーは表に無いので、同じ正規表現で前処理する gpt-2 として表に足す。
// 足し方は convert_hf_to_gguf_update.py が表を生成する形と同じ
const ZENZ_TOKENIZER_HASH =
  "acded0362f57dcca1fbdada8d4c87dd782c798cb4c510a70f12a9de6aea57857";
const PRE_TOKENIZER = "gpt-2";
// 表の終わり。ここの直前に足す
const TABLE_END = "\n        if res is None:\n";
const CONVERTER = "conversion/base.py";
// 設定とトークナイザーのファイル（リポジトリの直下のもの）。トークナイザーの形（tokenizer.json か vocab.json と merges.txt か）は
// モデルごとに違うので、在るものを全部取る
const META_FILES = [
  "config.json",
  "generation_config.json",
  "tokenizer.json",
  "tokenizer_config.json",
  "special_tokens_map.json",
  "vocab.json",
  "merges.txt",
  "model.safetensors.index.json",
];

const [repo, commit, outtype, name, ...extra] = process.argv.slice(2);
if (
  repo === undefined ||
  commit === undefined ||
  outtype === undefined ||
  name === undefined ||
  extra.length > 0
) {
  console.error(USAGE);
  process.exit(2);
}
// タグとブランチは後から動くので、コミットだけを受け付ける
if (!/^[0-9a-f]{40}$/.test(commit)) {
  console.error(`コミットは 40 桁の 16 進で渡す: ${commit}`);
  process.exit(2);
}

// 変換はディレクトリの名前から general.name などを作るので、最後をリポジトリの名前にする
const sourceDir = join(root, ".eval/hf", commit, repo);
await mkdir(sourceDir, { recursive: true });
// 取得は Hugging Face の公式 CLI。--local-dir に取得済みの記録を置き、取得済みなら取り直さない
// --include は 1 つの後ろにパターンを並べる。繰り返すと最後の 1 つだけが効く。標準出力は最後に出すパスだけにする
const hfDownload = [
  ...uvRun,
  "hf",
  "download",
  repo,
  "--revision",
  commit,
  "--local-dir",
  sourceDir,
  "--quiet",
  "--include",
];
console.error(`== 取得 ${repo} ${commit} の設定とトークナイザー`);
await $`${hfDownload} ${META_FILES} 1>&2`;
if (!(await Bun.file(join(sourceDir, "config.json")).exists()))
  throw new Error(`${repo} ${commit} に config.json が無い`);

/// 分割の目録の weight_map（テンソル名 → 重みのファイル名）に挙がったファイル名
async function indexedWeights(path: string): Promise<string[]> {
  const weightMap: unknown = (await Bun.file(path).json()).weight_map;
  if (typeof weightMap !== "object" || weightMap === null)
    throw new Error(`${path} に weight_map が無い`);
  const values: unknown[] = Object.values(weightMap);
  const files = values.filter((v): v is string => typeof v === "string");
  if (files.length !== values.length)
    throw new Error(`${path} の weight_map にファイル名でない値がある`);
  return [...new Set(files)].sort();
}

// 重みは transformers と同じく、分割の目録があればそこに書かれたファイル、無ければ model.safetensors だけを取る。
// 変換はディレクトリの safetensors をすべて読むので、IME 用の量子化版など別の重みを並べて置かない
const index = join(sourceDir, "model.safetensors.index.json");
const weights = (await Bun.file(index).exists())
  ? await indexedWeights(index)
  : ["model.safetensors"];
console.error(`== 取得 ${repo} ${commit} の重み ${weights.join(" ")}`);
await $`${hfDownload} ${weights} 1>&2`;
// 重みの組に入らない safetensors が置かれていれば止める（変換がそれも読むため）
for (const file of await readdir(sourceDir))
  if (file.endsWith(".safetensors") && !weights.includes(file))
    throw new Error(
      `重みの組に入らない ${join(sourceDir, file)} がある。消してからやり直す`,
    );

const llama = join(root, ".eval/llama.cpp");
const head = await $`git -C ${llama} rev-parse HEAD`.nothrow().quiet();
if (head.exitCode !== 0 || head.text().trim() !== LLAMA_COMMIT) {
  console.error(`== 取得 ${LLAMA_REPO} ${LLAMA_COMMIT}`);
  await rm(llama, { recursive: true, force: true });
  await $`git init -q ${llama}`;
  await $`git -C ${llama} fetch -q --depth 1 ${LLAMA_REPO} ${LLAMA_COMMIT}`;
  await $`git -C ${llama} checkout -q FETCH_HEAD`;
}
// 前回足した表の行を消してから足し直す
await $`git -C ${llama} checkout -q -- ${CONVERTER}`;
const converter = join(llama, CONVERTER);
const source = await Bun.file(converter).text();
if (source.split(TABLE_END).length !== 2)
  throw new Error(`${converter} に前処理の表の終わりが 1 つだけあるのではない`);
await Bun.write(
  converter,
  source.replace(
    TABLE_END,
    `\n        if chkhsh == "${ZENZ_TOKENIZER_HASH}":\n            res = "${PRE_TOKENIZER}"${TABLE_END}`,
  ),
);

// 変換は config.json の n_ctx を、モデルが学習した列の長さ（context_length）として書き、tugime はその長さまで列を伸ばす。
// しかし学習の列が n_ctx まで届いたとは限らない。届かなかった位置での変換は学習されていないので、その手前で切る。
// 学習の列が届かなかった位置の埋め込みの行は、初期値の大きさ（標準偏差 initializer_range）からほとんど動かず、学習した行とは標準偏差がはっきり分かれる（genmai-310M では、学習していない行は最大 0.029、学習した行は最小 0.049）。
// そこで標準偏差が initializer_range の 2 倍を超える先頭の行だけを残し、n_ctx と n_positions をその行数にした写しを変換する。
// llama.cpp は位置の埋め込みの行数が context_length と同じであることを求めるので、行も削る。学習した行が先頭に連続していなければ止める
const trimToTrainedPositions = `
import json, shutil, sys
from pathlib import Path
from safetensors.torch import load_file, save_file

source, dest, weights = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
config = json.loads((source / "config.json").read_text())
limit = 2 * config["initializer_range"]
tensors = {f: load_file(source / f) for f in weights}
found = [(f, k) for f, ts in tensors.items() for k in ts if k.endswith("wpe.weight")]
if len(found) != 1:
    sys.exit(f"位置の埋め込み（wpe.weight）が 1 つではない: {found}")
[(file, key)] = found
std = tensors[file][key].double().std(dim=1, correction=0)
trained = int((std > limit).sum())
if trained == 0:
    sys.exit(f"位置の埋め込みに、標準偏差が {limit} を超える行が無い")
if not bool((std[:trained] > limit).all()):
    sys.exit(f"位置の埋め込みの、標準偏差が {limit} を超える行が先頭に連続していない")
rest = std[trained:]
if dest.exists():
    shutil.rmtree(dest)
dest.mkdir(parents=True)
for path in source.iterdir():
    if path.is_file() and path.name not in weights:
        shutil.copy2(path, dest / path.name)
config["n_ctx"] = config["n_positions"] = trained
(dest / "config.json").write_text(json.dumps(config, indent=2, ensure_ascii=False))
tensors[file][key] = tensors[file][key][:trained].contiguous()
for f, ts in tensors.items():
    save_file(ts, dest / f, metadata={"format": "pt"})
print(json.dumps({"rows": len(std), "trained": trained, "trainedMin": float(std[:trained].min()), "restMax": float(rest.max()) if len(rest) else None}))
`;
// 変換はディレクトリの名前から general.name などを作るので、写しも最後をリポジトリの名前にする
const trimmedDir = join(root, ".eval/hf-trained", commit, repo);
const positions: {
  rows: number;
  trained: number;
  trainedMin: number;
  restMax: number | null;
} =
  await $`${uvRun} python -I - ${sourceDir} ${trimmedDir} ${weights} < ${new Response(trimToTrainedPositions)}`.json();
console.error(
  `== 位置の埋め込み ${positions.rows} 行のうち、学習した行 ${positions.trained} を残す（行の標準偏差は、学習した行の最小 ${positions.trainedMin.toFixed(4)}、残りの最大 ${positions.restMax?.toFixed(4) ?? "なし"}）`,
);
const trainedPositions = positions.trained;

const out = join(root, ".zenz", `${name}.gguf`);
await mkdir(join(root, ".zenz"), { recursive: true });
console.error(`== 変換 ${repo} ${commit} → ${out}（${outtype}）`);
await $`${uvRun} python ${join(llama, "convert_hf_to_gguf.py")} ${trimmedDir} --outtype ${outtype} --outfile ${out}.part 1>&2`;

// 書き出した GGUF の前処理の名前と学習した列の長さを、同じ版の gguf-py で読んで確かめる
const checkMetadata = `
import sys
sys.path.insert(0, sys.argv[1])
from gguf import GGUFReader

fields = GGUFReader(sys.argv[2]).fields
def value(key):
    field = fields[key]
    return field.parts[field.data[0]]
pre = bytes(value("tokenizer.ggml.pre")).decode()
if pre != sys.argv[3]:
    sys.exit(f"tokenizer.ggml.pre が {sys.argv[3]} でなく {pre}")
key = bytes(value("general.architecture")).decode() + ".context_length"
length = int(value(key)[0])
if length != int(sys.argv[4]):
    sys.exit(f"{key} が {sys.argv[4]} でなく {length}")
`;
await $`${uvRun} python - ${join(llama, "gguf-py")} ${out}.part ${PRE_TOKENIZER} ${trainedPositions} < ${new Response(checkMetadata)}`;
await rename(`${out}.part`, out);
console.log(out);
