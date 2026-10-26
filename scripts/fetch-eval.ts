// 精度と打鍵の検証に使う問題ファイルを .eval/problems/ に取得し、SHA-256 を確かめてディレクトリのパスを出す。
// 版はコミットで固定する。更新するときは revision と sha256 を一緒に変える。置くファイル名は Sources/TugimeEval/ProblemSources.swift の表と同じ。
// 問題はリポジトリに入れない（AJIMEE-Bench は CC-BY-SA 3.0、Mozc は BSD-3-Clause）
import { join } from "node:path";
import { fetchPinned } from "./lib/fetch";
import { root } from "./lib/root";

const ajimee =
  "https://raw.githubusercontent.com/azooKey/AJIMEE-Bench/401666cd56d1a570c2021798b64b6da4396bfd45";
const mozc =
  "https://raw.githubusercontent.com/google/mozc/a069a88d4cb5c011de0f9aebb6c149a1c808d904/src/data/test/quality_regression_test";

/// 置くファイル名・URL・SHA-256
const files = [
  [
    "ajimee-evaluation_items.json",
    `${ajimee}/JWTD_v2/v1/evaluation_items.json`,
    "e9eb668fd6aa14b1e26436f429b5550108af0a1dfd443b8cea0bcb3ab3028fca",
  ],
  [
    "mozc-oss.tsv",
    `${mozc}/oss.tsv`,
    "053a43e72d174da43b351278cadc471abe08cea9fe98829dafe3d152580fcff0",
  ],
  [
    "mozc-regression.tsv",
    `${mozc}/regression.tsv`,
    "adb5998cdae7e4ba1b746ddef17ac4148f991af5547e178fd50a10788f3a6a55",
  ],
] as const;

export async function problems(): Promise<string> {
  const dir = join(root, ".eval/problems");
  await fetchPinned(
    files.map(([name, url, sha256]) => ({
      url,
      sha256,
      path: join(dir, name),
    })),
  );
  return dir;
}

if (import.meta.main) console.log(await problems());
