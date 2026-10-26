// dist/tugime.app と install.sh を配布用の tar.gz にまとめる。先に TUGIME_BUILD_CHANNEL=stable bun scripts/build-app.ts を実行する。
// ルートに 2 項目を置く。ルートがディレクトリ 1 個だけの tar は、mise が strip_components=1 を当てて .app を崩すため
// 使い方: bun scripts/package.ts
import { $ } from "bun";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { root } from "./lib/root";

const dist = join(root, "dist");
const app = join(dist, "tugime.app");
const archive = join(dist, "tugime-macos-arm64.tar.gz");

if ((await $`test -d ${app}`.nothrow()).exitCode !== 0)
  throw new Error(
    `${app} が無い。先に TUGIME_BUILD_CHANNEL=stable bun scripts/build-app.ts を実行する`,
  );
const stage = await mkdtemp(join(tmpdir(), "tugime-package-"));
try {
  await $`ditto ${app} ${join(stage, "tugime.app")}`;
  await $`cp ${join(root, "install.sh")} ${join(stage, "install.sh")}`;
  await $`tar -C ${stage} -czf ${archive} tugime.app install.sh`;
} finally {
  await rm(stage, { recursive: true });
}
console.log(`== 作成 ${archive}`);
