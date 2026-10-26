// README と docs の図の字形を取り出すフォント（LINE Seed JP、SIL Open Font License 1.1）を
// .fonts/ に取得し、SHA-256 を確かめてディレクトリを出す。版は google/fonts のコミットで固定する
import { join } from "node:path";
import { fetchPinned } from "./lib/fetch";
import { root } from "./lib/root";

const base =
  "https://raw.githubusercontent.com/google/fonts/e7db6ca603fd4862010383ff17ffd6cc4ffac1c0/ofl/lineseedjp";

/// ファイル名・SHA-256
const files = [
  [
    "LINESeedJP-Bold.ttf",
    "67aec2dc10b3ad210d6f7d53b33bbfea42ea28e32fa3834624eee699a638d5ff",
  ],
  [
    "LINESeedJP-Regular.ttf",
    "04a6c0077ddb8ba5af3638bd76b4600708dde7b38df047b40fbe6f3af358d3c3",
  ],
] as const;

export async function fonts(): Promise<string> {
  const dir = join(root, ".fonts");
  await fetchPinned(
    files.map(([name, sha256]) => ({
      url: `${base}/${name}`,
      sha256,
      path: join(dir, name),
    })),
  );
  return dir;
}

if (import.meta.main) console.log(await fonts());
