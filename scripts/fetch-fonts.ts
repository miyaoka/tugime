// README と docs の図の字形を取り出すフォント（LINE Seed JP、SIL Open Font License 1.1）を
// .fonts/ に取得し、SHA-256 を確かめて太さごとのパスを返す。版は google/fonts のコミットで固定する
import { join } from "node:path";
import { fetchPinned } from "./lib/fetch";
import { root } from "./lib/root";

const base =
  "https://raw.githubusercontent.com/google/fonts/e7db6ca603fd4862010383ff17ffd6cc4ffac1c0/ofl/lineseedjp";

/// 太さごとのファイル名と SHA-256
const files = {
  bold: {
    name: "LINESeedJP-Bold.ttf",
    sha256: "67aec2dc10b3ad210d6f7d53b33bbfea42ea28e32fa3834624eee699a638d5ff",
  },
  regular: {
    name: "LINESeedJP-Regular.ttf",
    sha256: "04a6c0077ddb8ba5af3638bd76b4600708dde7b38df047b40fbe6f3af358d3c3",
  },
};

export type FontPaths = Record<keyof typeof files, string>;

export async function fonts(): Promise<FontPaths> {
  const path = (name: string) => join(root, ".fonts", name);
  await fetchPinned(
    Object.values(files).map(({ name, sha256 }) => ({
      url: `${base}/${name}`,
      sha256,
      path: path(name),
    })),
  );
  return { bold: path(files.bold.name), regular: path(files.regular.name) };
}
