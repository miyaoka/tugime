// 取り込む Mozc のコミット。システム辞書（fetch-dictionary.ts）と記号の候補の表（make-symbol-candidates.ts）が同じ版を使う。
// 更新するときは、両方のスクリプトの各ファイルの sha256 と、App/Notices/mozc-dictionary.txt・mozc-symbol.txt の版を一緒に変える
import { join } from "node:path";
import { fetchPinned } from "./fetch";
import { root } from "./root";

export const mozcCommit = "c4b2aef7c65e61be394bacadaec200eb5b97f91c";

/// 取得した Mozc の src の置き場所
export const mozcSource = join(root, `.dictionary/mozc-${mozcCommit}/src`);

/// Mozc の src からのパスと SHA-256 の組を取得する
export async function fetchMozc(files: readonly (readonly [string, string])[]) {
  await fetchPinned(
    files.map(([path, sha256]) => ({
      url: `https://raw.githubusercontent.com/google/mozc/${mozcCommit}/src/${path}`,
      sha256,
      path: join(mozcSource, path),
    })),
  );
}
