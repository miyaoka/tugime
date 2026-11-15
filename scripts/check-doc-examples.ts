// README と docs の表に載せた変換の結果を、今の tugime-cli の出力と突き合わせる。合わない行があれば終了コード 1 で終わる。
// 使い方: bun scripts/check-doc-examples.ts
import { join } from "node:path";
import { root } from "./lib/root";
import { cli, prepareCli, readPerInput, run, step } from "./lib/svg";

const DOCS = ["README.md", "docs/how-it-works.md", "docs/limitations.md"];

/// live は入力メソッドと同じ方式の表示、lattice は --method lattice の表示、reading は綴りの表による読み（F6）
type Method = "live" | "lattice" | "reading";
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
  ["打った読み", "reading"],
]);
/// 「`打鍵` で 表示」。打鍵列に続けて打ったときの表示
const CONTINUED = "続けて打つと";
/// 突き合わせない列。人が打って確かめた他の入力方式の結果と、期待する表記
const UNCHECKED = new Set(["日本語モードのライブ変換", "期待"]);
const KEYS = /^`([^`]+)`$/;

const cells = (line: string) =>
  line
    .trim()
    .replace(/^\||\|$/g, "")
    .split("|")
    .map((c) => c.trim());

/// 文書の表から、突き合わせる行を取り出す
function collect(doc: string, text: string): Check[] {
  const checks: Check[] = [];
  let header: string[] | undefined;
  text.split("\n").forEach((line, i) => {
    const at = `${doc}:${i + 1}`;
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
      throw new Error(`${at} の列の数が見出しと合わない`);
    header.forEach((column, j) => {
      const cell = row[j];
      if (j === 0 || cell === undefined || UNCHECKED.has(column)) return;
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
      if (column !== CONTINUED)
        throw new Error(
          `${at} の列「${column}」を突き合わせるか決まっていない。METHOD_OF_COLUMN か UNCHECKED に足す`,
        );
      const m = cell.match(/^`([^`]+)` で (.+)$/);
      if (!m?.[1] || !m[2])
        throw new Error(
          `${at} の「${CONTINUED}」が「\`打鍵\` で 表示」の形でない: ${cell}`,
        );
      checks.push({
        doc,
        line: i + 1,
        column,
        method: "live",
        input: input + m[1],
        expected: m[2],
      });
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
if (checks.length === 0) throw new Error("突き合わせる行が 1 つも無い");

await prepareCli();
const inputsOf = (method: Method) => [
  ...new Set(checks.filter((c) => c.method === method).map((c) => c.input)),
];
const results = new Map<string, string>();
const put = (method: Method, input: string, value: string) =>
  results.set(`${method}\t${input}`, value);

// 表示の変換は前の打鍵列の生成を覚えて使うことがあるので、入力メソッドと同じく打鍵列ごとに別の実行にする
const liveInputs = inputsOf("live");
await step(
  `入力メソッドと同じ方式の表示（${liveInputs.length} 件）`,
  async () => {
    for (const input of liveInputs) {
      const [r] = readPerInput("--live", await run([cli, "--live", input]), [
        input,
      ]);
      if (r) put("live", input, r.shown);
    }
  },
);
const latticeInputs = inputsOf("lattice");
if (latticeInputs.length > 0)
  for (const r of await step(
    `--method lattice の表示（${latticeInputs.length} 件）`,
    async () =>
      readPerInput(
        "--live",
        await run([cli, "--method", "lattice", "--live", ...latticeInputs]),
        latticeInputs,
      ),
  ))
    put("lattice", r.input, r.shown);
const readingInputs = inputsOf("reading");
if (readingInputs.length > 0)
  for (const r of await step(
    `綴りの表による読み（${readingInputs.length} 件）`,
    async () =>
      readPerInput(
        "--whole",
        await run([cli, "--whole", ...readingInputs]),
        readingInputs,
      ),
  )) {
    const hiragana = r.shown.split(" / ")[0];
    if (hiragana === undefined)
      throw new Error(`--whole の結果が無い: ${r.input}`);
    put("reading", r.input, hiragana);
  }

let failed = 0;
for (const c of checks) {
  const actual = results.get(`${c.method}\t${c.input}`);
  const ok = actual === c.expected;
  if (!ok) failed++;
  console.log(
    `${ok ? "一致" : "不一致"}\t${c.doc}:${c.line}\t${c.column}\t${c.input}\t表: ${c.expected}${ok ? "" : `\t今: ${actual}`}`,
  );
}
console.log(`全 ${checks.length} 件中 ${failed} 件が合わない`);
if (failed > 0) process.exit(1);
