// .app を dist/ に組み立てて ad-hoc で署名する。鍵束は使わない。
// 無指定は開発版にする。手元で組み立てたものが配布版と同じ bundle id を名乗り、入れた配布版を上書きしないようにするため
// 使い方: [TUGIME_BUILD_CHANNEL=stable] [TUGIME_VERSION=<版>] bun scripts/build-app.ts
import { $ } from "bun";
import { mkdir, mkdtemp, readdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { genmai } from "./fetch-genmai";
import { root } from "./lib/root";

const BUNDLE_ID = "io.github.miyaoka.inputmethod.tugime";
/// TUGIME_BUILD_CHANNEL ごとの bundle id と名前。無指定（空）は開発版
const CHANNELS = new Map([
  ["stable", { bundleId: BUNDLE_ID, name: "tugime" }],
  ["", { bundleId: `${BUNDLE_ID}.dev`, name: "tugime Dev" }],
]);

const channelName = process.env.TUGIME_BUILD_CHANNEL ?? "";
const channel = CHANNELS.get(channelName);
if (!channel)
  throw new Error(`TUGIME_BUILD_CHANNEL は stable か無指定: ${channelName}`);
const { bundleId, name } = channel;
const version = process.env.TUGIME_VERSION || "0.0.0";
const app = join(root, "dist", `${name}.app`);

// SwiftPM の既定のビルドの仕組みは toolchain の版で違う。native はリソースを .app の Contents/Resources から探さないので、swiftbuild に固定する。
// 対象は Apple Silicon だけなので arm64 だけを組み立てる。swiftbuild は指定しないと Intel 向けも含めた universal にする
const build = [
  "swift",
  "build",
  "--package-path",
  root,
  "-c",
  "release",
  "--build-system",
  "swiftbuild",
  "--arch",
  "arm64",
];

/// テンプレートの __KEY__ を値に置き換えて書き、plutil で確かめる
async function fill(
  template: string,
  out: string,
  values: Record<string, string>,
) {
  let text = await Bun.file(template).text();
  for (const [key, value] of Object.entries(values))
    text = text.replaceAll(`__${key}__`, value);
  await Bun.write(out, text);
  await $`plutil -lint ${out}`;
}

console.log("== 表示の変換のモデル");
const model = await genmai();

console.log("== swift build");
await $`${build} --product tugime`;
const bin = (await $`${build} --show-bin-path`.text()).trim();

console.log(`== 組み立て ${app}`);
await rm(app, { recursive: true, force: true });
for (const dir of ["MacOS", "Resources/model", "Frameworks"])
  await mkdir(join(app, "Contents", dir), { recursive: true });
await $`cp ${join(bin, "tugime")} ${join(app, "Contents/MacOS/tugime")}`;
// モデルの推論に使う llama.cpp。実行ファイルは @rpath/llama.framework を探すので、Frameworks を探し場所に足す
await $`cp -R ${join(bin, "llama.framework")} ${join(app, "Contents/Frameworks/")}`;
// 配られている llama.framework は Intel 向けも含む。対象は Apple Silicon だけなので arm64 だけを残す
const llama = await realpath(
  join(app, "Contents/Frameworks/llama.framework/llama"),
);
if ((await $`lipo -archs ${llama}`.text()).trim() !== "arm64")
  await $`lipo -thin arm64 ${llama} -output ${llama}`;
await $`install_name_tool -add_rpath @executable_path/../Frameworks ${join(app, "Contents/MacOS/tugime")}`;
await $`cp ${model} ${join(app, "Contents/Resources/model/")}`;
for (const entry of await readdir(bin))
  if (entry.endsWith(".bundle"))
    await $`cp -R ${join(bin, entry)} ${join(app, "Contents/Resources/")}`;
await fill(join(root, "App/Info.plist"), join(app, "Contents/Info.plist"), {
  BUNDLE_ID: bundleId,
  VERSION: version,
  NAME: name,
});
// 入力ソースの一覧に出るモードの表示名
for (const lproj of ["en.lproj", "ja.lproj"]) {
  await mkdir(join(app, "Contents/Resources", lproj), { recursive: true });
  await fill(
    join(root, "App", lproj, "InfoPlist.strings"),
    join(app, "Contents/Resources", lproj, "InfoPlist.strings"),
    { NAME: name },
  );
}
await $`swift ${join(root, "scripts/make-icons.swift")} ${join(app, "Contents/Resources")}`;
await $`swift ${join(root, "scripts/collect-notices.swift")} ${root} ${join(app, "Contents/Resources")} ${join(app, "Contents/Resources/ThirdPartyNotices.txt")}`;

console.log("== ad-hoc 署名");
// 入れ子のフレームワークは外側の署名では署名されない。arm64 だけにして中身が変わったので署名し直す
await $`codesign --force --timestamp=none --sign - ${join(app, "Contents/Frameworks/llama.framework")}`;
const work = await mkdtemp(join(tmpdir(), "tugime-build-"));
try {
  const entitlements = join(work, "tugime.entitlements");
  await fill(join(root, "App/tugime.entitlements"), entitlements, {
    BUNDLE_ID: bundleId,
  });
  await $`codesign --force --timestamp=none --sign - --entitlements ${entitlements} ${app}`;
} finally {
  await rm(work, { recursive: true, force: true });
}
await $`codesign --verify --strict ${app}`;
console.log(`== 完了 ${app}`);
