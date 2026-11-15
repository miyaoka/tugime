// README と docs の表に載せた変換の結果が、今の tugime-cli の出力と合うかを確かめる。
// 表は手で書くので、変換が変わると黙って古くなる。合わない行を並べて終了コード 1 で終わる。
// 確かめるのは、1 列目が打鍵列（`...`）の表のうち、見出しが次の列だけである。
//   tugime / 表示                       … 入力メソッドと同じ方式の表示（--live）
//   英語を見分けて辞書と統計で変換       … --method lattice の表示
//   続けて打つと                         … 「`打鍵` で 表示」。打鍵列に続けて打ったときの表示
// ほかの列（人間が打って確かめた他の入力方式の結果、期待する表記、打った読み）は確かめない。
// 使い方: bun scripts/check-doc-examples.ts
import { join } from "node:path";
import { genmai } from "./fetch-genmai";
import { root } from "./lib/root";
import { cli, readLive, run, step } from "./lib/svg";

const DOCS = ["README.md", "docs/how-it-works.md", "docs/limitations.md"];

type Method = "live" | "lattice";
type Check = {
  doc: string;
  line: number;
  column: string;
  method: Method;
  input: string;
  expected: string;
};

const METHOD_OF_COLUMN = new Map<string, Method>([
  ["tugime", "live"],
  ["表示", "live"],
  ["英語を見分けて辞書と統計で変換", "lattice"],
]);
const CONTINUED = "続けて打つと";
const KEYS = /^`([^`]+)`$/;

const cells = (line: string) =>
  line
    .trim()
    .replace(/^\||\|$/g, "")
    .split("|")
    .map((c) => c.trim());

/// 文書の表から、確かめる行を取り出す
function collect(doc: string, text: string): Check[] {
  const checks: Check[] = [];
  const lines = text.split("\n");
  let header: string[] | undefined;
  lines.forEach((line, i) => {
    if (!line.startsWith("|")) {
      header = undefined;
      return;
    }
    const row = cells(line);
    if (header === undefined) {
      header = row;
      return;
    }
    if (row.every((c) => /^-+$/.test(c))) return;
    const input = row[0]?.match(KEYS)?.[1];
    if (input === undefined) return;
    if (row.length !== header.length)
      throw new Error(`${doc}:${i + 1} の列の数が見出しと合わない`);
    header.forEach((column, j) => {
      const cell = row[j];
      if (j === 0 || cell === undefined) return;
      const method = METHOD_OF_COLUMN.get(column);
      if (method) {
        checks.push({
          doc,
          line: i + 1,
          column,
          method,
          input,
          expected: cell,
        });
        return;
      }
      if (column === CONTINUED) {
        const m = cell.match(/^`([^`]+)` で (.+)$/);
        if (!m?.[1] || !m[2])
          throw new Error(
            `${doc}:${i + 1} の「${CONTINUED}」が「\`打鍵\` で 表示」の形でない: ${cell}`,
          );
        checks.push({
          doc,
          line: i + 1,
          column,
          method: "live",
          input: input + m[1],
          expected: m[2],
        });
      }
    });
  });
  return checks;
}

const checks = (
  await Promise.all(
    DOCS.map(async (doc) =>
      collect(doc, await Bun.file(join(root, doc)).text()),
    ),
  )
).flat();
if (checks.length === 0) throw new Error("確かめる行が 1 つも無い");

const model = await step("表示の変換のモデルの用意", genmai);
await step("tugime-cli の組み立て", () =>
  run(["swift", "build", "-c", "release", "--product", "tugime-cli"]),
);
const shown = new Map<string, string>();
for (const [method, args] of [
  ["live", ["--method", `direct:${model}`]],
  ["lattice", ["--method", "lattice"]],
] as const) {
  const inputs = [
    ...new Set(checks.filter((c) => c.method === method).map((c) => c.input)),
  ];
  if (inputs.length === 0) continue;
  const results = await step(
    `${method} の表示（${inputs.length} 件）`,
    async () =>
      readLive(await run([cli, ...args, "--live", ...inputs]), inputs),
  );
  for (const r of results) shown.set(`${method}\t${r.input}`, r.shown);
}

let failed = 0;
for (const c of checks) {
  const actual = shown.get(`${c.method}\t${c.input}`);
  const ok = actual === c.expected;
  if (!ok) failed++;
  console.log(
    `${ok ? "一致" : "不一致"}\t${c.doc}:${c.line}\t${c.column}\t${c.input}\t表: ${c.expected}${ok ? "" : `\t今: ${actual}`}`,
  );
}
console.log(`全 ${checks.length} 件中 ${failed} 件が合わない`);
if (failed > 0) process.exit(1);
