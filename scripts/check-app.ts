// 引数の組み立てた .app について、組み立てたディレクトリ（.build）に頼らずに綴りの表・語表・辞書・利用者の辞書を組み立てる文字の表・表示の変換のモデル・llama.framework を
// 読めることと、署名の entitlements が想定どおりであることと、実行ファイルと llama.framework が Apple Silicon 向け（arm64）だけを含むことを確かめる。
// SwiftPM の生成するリソースの探し方はビルドの仕組みで違い、組み立てたマシンの絶対パスを探すものがあるので、.build を退避して実行する
import { $ } from "bun";
import assert from "node:assert";
import {
  existsSync,
  mkdtempSync,
  realpathSync,
  renameSync,
  rmdirSync,
} from "node:fs";
import { constants } from "node:os";
import { join } from "node:path";
import { root } from "./lib/root";

const USAGE = "使い方: bun scripts/check-app.ts <.app>";
/// 受けて .build を戻してから止めるシグナル
const SIGNALS = ["SIGHUP", "SIGINT", "SIGTERM"] as const;

const [appArgument, ...extra] = process.argv.slice(2);
if (appArgument === undefined || extra.length > 0) {
  console.error(USAGE);
  process.exit(2);
}
const app = realpathSync(appArgument);

// 退避先はリポジトリの中に置く。同じボリュームなので rename で動き、OS の一時ディレクトリの掃除で消されない。
// 戻すのは exit のとき。シグナルでは exit が出ないので、受けて process.exit を呼ぶ（Bun の文書 OS signals）
const build = join(root, ".build");
if (!existsSync(build))
  throw new Error(
    `${build} が無い。先に bun scripts/build-app.ts で組み立てる`,
  );
const aside = mkdtempSync(join(root, ".check-aside-"));
renameSync(build, join(aside, ".build"));
process.on("exit", () => {
  renameSync(join(aside, ".build"), build);
  rmdirSync(aside);
});
// シグナルで止まったときの終了コードは、シェルと同じく 128 + シグナルの番号
for (const signal of SIGNALS)
  process.on(signal, () => process.exit(128 + constants.signals[signal]));

await $`${join(app, "Contents/MacOS/tugime")} --check`;

// App Sandbox で動き、権限は入力メソッドの接続の名前の登録だけ。通信の権限が付いていれば止める
const connection = (
  await $`plutil -extract InputMethodConnectionName raw ${join(app, "Contents/Info.plist")}`.text()
).trim();
const expected = {
  "com.apple.security.app-sandbox": true,
  "com.apple.security.temporary-exception.mach-register.global-name":
    connection,
};
const actual: unknown =
  await $`codesign -d --entitlements - --xml ${app} | plutil -convert json -o - -`.json();
assert.deepStrictEqual(actual, expected, "entitlements が想定と違う");
console.log(`entitlements ${JSON.stringify(actual)}`);

// 対象は Apple Silicon だけなので、実行ファイルと同梱のフレームワークは arm64 だけを含む
for (const binary of [
  "Contents/MacOS/tugime",
  "Contents/Frameworks/llama.framework/llama",
]) {
  const archs = (await $`lipo -archs ${join(app, binary)}`.text()).trim();
  if (archs !== "arm64")
    throw new Error(`対象が arm64 だけではない: ${binary} ${archs}`);
  console.log(`対象 ${archs} ${binary.split("/").at(-1)}`);
}
