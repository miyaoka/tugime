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

const out = join(root, ".zenz", `${name}.gguf`);
await mkdir(join(root, ".zenz"), { recursive: true });
console.error(`== 変換 ${repo} ${commit} → ${out}（${outtype}）`);
await $`${uvRun} python ${join(llama, "convert_hf_to_gguf.py")} ${sourceDir} --outtype ${outtype} --outfile ${out}.part 1>&2`;

// 書き出した GGUF の前処理の名前を、同じ版の gguf-py で読んで確かめる
const checkPreTokenizer = `
import sys
sys.path.insert(0, sys.argv[1])
from gguf import GGUFReader

field = GGUFReader(sys.argv[2]).fields["tokenizer.ggml.pre"]
pre = bytes(field.parts[field.data[0]]).decode()
if pre != sys.argv[3]:
    sys.exit(f"tokenizer.ggml.pre が {sys.argv[3]} でなく {pre}")
`;
await $`${uvRun} python - ${join(llama, "gguf-py")} ${out}.part ${PRE_TOKENIZER} < ${new Response(checkPreTokenizer)}`;
await rename(`${out}.part`, out);
console.log(out);
