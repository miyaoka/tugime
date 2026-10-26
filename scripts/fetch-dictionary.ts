// システム辞書の元（Mozc の OSS 辞書・連接の表・文節の境目の規則）を .dictionary/ に取得して SHA-256 を確かめ、
// tugime-dictionary で 1 つのファイルに組み立ててパスを出す。組み立てたファイルが無いか、組み立ての道具と並びのソースより古ければ組み立て直す。
// 版は Mozc のコミットで固定する。更新するときは commit と各ファイルの sha256 と、App/Notices/mozc-dictionary.txt の版を一緒に変える
import { $ } from "bun";
import { readdir, rename, stat } from "node:fs/promises";
import { join } from "node:path";
import { fetchPinned } from "./lib/fetch";
import { root } from "./lib/root";

const commit = "c4b2aef7c65e61be394bacadaec200eb5b97f91c";

/// Mozc の src からのパスと SHA-256
const files: [string, string][] = [
  [
    "data/dictionary_oss/dictionary00.txt",
    "9e07ce292932c4fff327ed8cb06274c09acca556bd8bdf7c7ef1f6173eae3b61",
  ],
  [
    "data/dictionary_oss/dictionary01.txt",
    "836fd5fd8399510de0d8ef7b33be913cca6bbaee7b712cc8045fba03f4c75a89",
  ],
  [
    "data/dictionary_oss/dictionary02.txt",
    "93943858d0cfd092b849a78def6901eaf228177e1ac5663544e865a3a1e45a9e",
  ],
  [
    "data/dictionary_oss/dictionary03.txt",
    "cb9f1b0b4a7550d682d86244a021cd17e0b15366328819e69135b5f183a1a24b",
  ],
  [
    "data/dictionary_oss/dictionary04.txt",
    "9fdc4e3948d03463de13ab5782adffbc11dd06e934cb80138c5920029cd3d2f6",
  ],
  [
    "data/dictionary_oss/dictionary05.txt",
    "199e3b0f050b691823ae7ba943090d437f51af6436b27c5f3dc69cafa12000e4",
  ],
  [
    "data/dictionary_oss/dictionary06.txt",
    "b95b14f7770ae2a824bc8e9fad8b03c1bc45c504f93a36554b8b56daa0368d2a",
  ],
  [
    "data/dictionary_oss/dictionary07.txt",
    "7f53649b529d4c8c495d3a8dd9c4d489dfe7696080f7423107ff01331174be48",
  ],
  [
    "data/dictionary_oss/dictionary08.txt",
    "50a31bb5fc1646721b00be371a5695dffab1292bda143e1e59cc70cbbdd8643f",
  ],
  [
    "data/dictionary_oss/dictionary09.txt",
    "4e5fcd4cbfbf11395166a37b506f547fc54d20edc0884f5184ecd3fc705f0d9a",
  ],
  [
    "data/dictionary_oss/connection_single_column.txt",
    "68823a1f6617372ccb89afdbcb334d7a0bcfa82c9c5dda03fc1f80f1cab5c48e",
  ],
  [
    "data/dictionary_oss/id.def",
    "07a05a268c3783b7e02b36e4aa591555a2dd19a1f3c93891576740761c154f2d",
  ],
  [
    "data/rules/segmenter.def",
    "faf14ec987a12e36c796b35b4f84e210c6a780f5ae52bddc7f80accc58861b21",
  ],
];

/// 組み立ての結果を変えるソース。版の固定を変えたときも組み立て直すよう、このファイル自身も入れる
const builders = [
  "Sources/tugime-dictionary",
  "Sources/SystemDictionaryLayout",
  "scripts/fetch-dictionary.ts",
];

/// ファイルか、ディレクトリの中で最も新しいファイルの更新時刻
async function newest(path: string): Promise<number> {
  if (!(await stat(path)).isDirectory()) return (await stat(path)).mtimeMs;
  const names = await readdir(path, { recursive: true });
  const times = await Promise.all(
    names.map(async (name) => (await stat(join(path, name))).mtimeMs),
  );
  return Math.max(...times);
}

export async function dictionary(): Promise<string> {
  const source = join(root, `.dictionary/mozc-${commit}/src`);
  await fetchPinned(
    files.map(([path, sha256]) => ({
      url: `https://raw.githubusercontent.com/google/mozc/${commit}/src/${path}`,
      sha256,
      path: join(source, path),
    })),
  );
  const out = join(root, ".dictionary/tugime-dictionary.bin");
  const built = await stat(out).then(
    (s) => s.mtimeMs,
    () => undefined,
  );
  const changed = Math.max(
    ...(await Promise.all(builders.map((dir) => newest(join(root, dir))))),
  );
  if (built === undefined || changed > built) {
    console.error(`== 組み立て ${out}`);
    // 標準出力にはパスだけを出すので、組み立ての出力は標準エラーに回す
    await $`swift build --package-path ${root} -c release --product tugime-dictionary 1>&2`;
    const bin = (
      await $`swift build --package-path ${root} -c release --show-bin-path`.text()
    ).trim();
    await $`${join(bin, "tugime-dictionary")} ${source} ${out}.part 1>&2`;
    await rename(`${out}.part`, out);
  }
  return out;
}

if (import.meta.main) console.log(await dictionary());
