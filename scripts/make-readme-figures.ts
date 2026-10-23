// README の図を作る。docs/images/conversion.html を tugime-cli の出力から生成し、
// conversion.html と intro.html を Chrome で PNG に書き出す。
// 使い方: bun scripts/make-readme-figures.ts
import { dirname, join } from "node:path";

const root = join(dirname(import.meta.path), "..");
const images = join(root, "docs/images");
const cli = join(root, ".build/debug/tugime-cli");
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const COMMAND_TIMEOUT_MS = 300_000;
const WIDTH = 1100;
const INTRO_HEIGHT = 540;

/// 変換の図に載せる例文。hide が英語、日本語、英語と入れ替わる
const input = "setteiwohidesitamamanisuru";
/// 最後まで打ったときに表示されるはずの文
const expected = "設定をhideしたままにする";
/// 「採った読み方」に並べる時点（打鍵の数）
const stepEnds = [6, 8, 12, 16, 20, 22, 24, 25, 26];
/// 最後に入れ替わる語と、入れ替わりの前後で比べる時点（打鍵の数）
const flippedWord = "hide";
const versusEnds = [24, 26];

const CELL = 33;
const AXIS_LEFT = 196;
const LINE = 2;
const LINE_GAP = 1;
const BAR = 30;
const ROW_GAP = 10;

const started = Date.now();
const elapsed = () => `${((Date.now() - started) / 1000).toFixed(1)}秒`;

async function run(command: string[]): Promise<string> {
  const proc = Bun.spawn(command, { cwd: root, stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => proc.kill(), COMMAND_TIMEOUT_MS);
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  const code = await proc.exited;
  clearTimeout(timer);
  if (code !== 0) throw new Error(`失敗 (${code}): ${command.join(" ")}\n${err.slice(-2000)}`);
  return out;
}

async function step<T>(name: string, task: () => Promise<T>): Promise<T> {
  console.error(`${name} 開始 ${elapsed()}`);
  const result = await task();
  console.error(`${name} 完了 ${elapsed()}`);
  return result;
}

type Kind = "J" | "E" | "P";
type Segment = { kind: Kind; s: number; e: number; output: string };
type Span = { s: number; e: number; after: string; kind: "J" | "E"; output: string; score: number };

/// --explain と --lattice の区間の表記 K[打鍵→出力 点]
const segmentPattern = /([JEP])\[(.*?)→(.*?) (-?[\d.]+)\]/g;

function parseSegments(described: string): Segment[] {
  let pos = 0;
  return [...described.matchAll(segmentPattern)].map((m) => {
    const segment = { kind: m[1] as Kind, s: pos, e: pos + m[2].length, output: m[3] };
    pos = segment.e;
    return segment;
  });
}

/// 打鍵列の途中までごとの、区切り（--explain）と表示（--live）
async function readSteps(prefixes: string[], zenz: string) {
  const explainOut = await run([cli, "--explain", ...prefixes]);
  const explainLines = explainOut.split("\n").filter((l) => /\t[EJP]\[/.test(l));
  if (explainLines.length !== prefixes.length) throw new Error(`--explain の行数 ${explainLines.length} が ${prefixes.length} と合わない`);
  const liveOut = await run([cli, "--zenz", zenz, "--live", ...prefixes]);
  return prefixes.map((prefix, i) => {
    const line = liveOut.split("\n").find((l) => l.startsWith(`${prefix}\t`));
    if (!line) throw new Error(`--live の結果が無い: ${prefix}`);
    return { prefix, segments: parseSegments(explainLines[i].split("\t")[1]), shown: line.split("\t")[1] };
  });
}

/// 表示の文字列を区間ごとに分ける。英語と句読点の区間は出力がそのまま表示に出るので、その間を日本語の区間の表示とする
function splitShown(segments: Segment[], shown: string): string[] {
  let cursor = 0;
  return segments.map((segment, i) => {
    if (segment.kind !== "J") {
      if (!shown.startsWith(segment.output, cursor)) throw new Error(`表示 ${shown} の ${cursor} 文字目に ${segment.output} が無い`);
      cursor += segment.output.length;
      return segment.output;
    }
    const next = segments.slice(i + 1).find((s) => s.kind !== "J");
    const end = next ? shown.indexOf(next.output, cursor) : shown.length;
    if (end < cursor) throw new Error(`表示 ${shown} に ${next!.output} が無い`);
    const text = shown.slice(cursor, end);
    cursor = end;
    return text;
  });
}

/// 打鍵列ごとの、区切りの採点で比べた区間の候補
async function readLattices(inputs: string[]): Promise<Map<string, Span[]>> {
  const out = await run([cli, "--lattice", ...inputs]);
  const lattices = new Map<string, Span[]>();
  let current: Span[] | undefined;
  for (const line of out.split("\n")) {
    const head = line.match(/^== (\S+)\t/);
    if (head) {
      current = [];
      lattices.set(head[1], current);
      continue;
    }
    const m = line.match(/^(\d+)\.\.<(\d+)\t(\S)\t([JE])\[.*?→(.*?) (-?[\d.]+)\]$/);
    if (m && current) current.push({ s: +m[1], e: +m[2], after: m[3], kind: m[4] as "J" | "E", output: m[5], score: +m[6] });
  }
  for (const i of inputs) if (!lattices.get(i)?.length) throw new Error(`--lattice の候補が無い: ${i}`);
  return lattices;
}

type Path = { total: number; spans: Span[] };

/// 区間の候補を、直前の区間の種類が合うようにつないだ並びのうち、合計の最も高いもの。allow で使える区間を、must で含むべき区間を絞る
function bestPath(spans: Span[], length: number, allow: (s: Span) => boolean, must: (s: Span) => boolean = () => true): Path | undefined {
  const table: Map<string, Path & { hit: boolean }>[] = Array.from({ length: length + 1 }, () => new Map());
  table[0].set("-|false", { total: 0, spans: [], hit: false });
  for (let pos = 0; pos < length; pos++) {
    for (const [key, cell] of table[pos]) {
      const previous = key.split("|")[0];
      for (const span of spans) {
        if (span.s !== pos || span.after !== previous || !allow(span)) continue;
        const hit = cell.hit || must(span);
        const total = cell.total + span.score;
        const k = `${span.kind}|${hit}`;
        const existing = table[span.e].get(k);
        if (!existing || existing.total < total) table[span.e].set(k, { total, spans: [...cell.spans, span], hit });
      }
    }
  }
  return [...table[length].values()].filter((c) => c.hit).sort((a, b) => b.total - a.total)[0];
}

/// 隣り合う日本語の区間をまとめた位置。--explain の区切りと比べるのに使う
function mergedBounds(spans: { kind: string; s: number; e: number }[]): string {
  const merged: { kind: string; s: number; e: number }[] = [];
  for (const span of spans) {
    const last = merged[merged.length - 1];
    if (last && last.kind === "J" && span.kind === "J") last.e = span.e;
    else merged.push({ ...span });
  }
  return merged.map((m) => `${m.kind}${m.s}-${m.e}`).join(" ");
}

const zenz = await step("Zenzai のモデルの取得", async () => (await run([join(root, "scripts/fetch-zenz.sh")])).trim().split("\n").pop()!);
await step("tugime-cli の組み立て", () => run(["swift", "build", "--product", "tugime-cli"]));

const stepPrefixes = stepEnds.map((end) => input.slice(0, end));
const steps = await step("各時点の区切りと表示", () => readSteps(stepPrefixes, zenz));
const versusPrefixes = versusEnds.map((end) => input.slice(0, end));
const lattices = await step("区間の候補", () => readLattices([...new Set([input, ...versusPrefixes])]));

const lattice = lattices.get(input)!;
const chosen = bestPath(lattice, input.length, () => true);
if (!chosen) throw new Error("最後まで打ったときの並びが見つからない");
const finalStep = steps[steps.length - 1];
if (finalStep.prefix !== input) throw new Error(`最後の時点 ${finalStep.prefix} が打鍵列の全体ではない`);
if (finalStep.shown !== expected) throw new Error(`最後まで打ったときの表示 ${finalStep.shown} が期待する文 ${expected} と違う`);
const finalSegments = finalStep.segments;
if (mergedBounds(chosen.spans) !== mergedBounds(finalSegments)) {
  throw new Error(`候補から求めた並び ${mergedBounds(chosen.spans)} が --explain の ${mergedBounds(finalSegments)} と合わない`);
}
const chosenKeys = new Set(chosen.spans.map((s) => `${s.s}-${s.e}-${s.kind}`));

const flippedStart = input.indexOf(flippedWord);
if (flippedStart < 0) throw new Error(`${flippedWord} が ${input} に無い`);
const isFlipped = (s: Span) => s.kind === "E" && s.s === flippedStart && s.e === flippedStart + flippedWord.length;
const versus = versusPrefixes.map((prefix) => {
  const spans = lattices.get(prefix)!;
  const japanese = bestPath(spans, prefix.length, (s) => s.kind === "J");
  const english = bestPath(spans, prefix.length, () => true, isFlipped);
  if (!japanese || !english) throw new Error(`比べる並びが見つからない: ${prefix}`);
  return { prefix, japanese, english };
});

// 区間の候補を、始まりの早い順、長い順に、重ならない段へ詰める
const unique = new Map<string, Span>();
for (const span of lattice) unique.set(`${span.s}-${span.e}-${span.kind}`, span);
const laneEnds: number[] = [];
const placed = [...unique.values()]
  .sort((a, b) => a.s - b.s || b.e - a.e)
  .map((span) => {
    let lane = laneEnds.findIndex((end) => end <= span.s);
    if (lane < 0) {
      lane = laneEnds.length;
      laneEnds.push(span.e);
    } else laneEnds[lane] = span.e;
    return { ...span, lane };
  });

const x = (pos: number) => AXIS_LEFT + pos * CELL;
const latticeHeight = laneEnds.length * (LINE + LINE_GAP);
const stepsHeight = steps.length * (BAR + ROW_GAP);
const height = 530 + latticeHeight + stepsHeight;

// 打ちたい文を、区間ごとにその打鍵の範囲の下へ置く
const expectedHtml = splitShown(finalSegments, finalStep.shown)
  .map((text, i) => {
    const s = finalSegments[i];
    return `<span class="goal-text ${s.kind}" style="left:${x(s.s)}px;width:${(s.e - s.s) * CELL}px">${text}</span>`;
  })
  .join("");

const keysHtml = [...input].map((c, i) => `<span class="c" style="left:${x(i)}px">${c}</span>`).join("");
const latticeHtml = placed
  .map((p) => `<i class="ln ${p.kind}${chosenKeys.has(`${p.s}-${p.e}-${p.kind}`) ? " on" : ""}" style="left:${x(p.s) + 1}px;top:${p.lane * (LINE + LINE_GAP)}px;width:${(p.e - p.s) * CELL - 2}px"></i>`)
  .join("");
const stepsHtml = steps
  .map((step, row) => {
    const top = row * (BAR + ROW_GAP);
    const texts = splitShown(step.segments, step.shown);
    const bars = step.segments
      .map((s, i) => `<span class="bar ${s.kind}" style="left:${x(s.s) + 1}px;top:${top}px;width:${(s.e - s.s) * CELL - 2}px">${texts[i]}</span>`)
      .join("");
    const previousEnd = row === 0 ? 0 : stepEnds[row - 1];
    const keys = `${row === 0 ? "" : "+"}${step.prefix.slice(previousEnd)}`;
    return `<span class="rowlbl" style="top:${top}px">${keys}</span>${bars}`;
  })
  .join("");
const pathCell = (path: Path, win: boolean) =>
  `<td${win ? ' class="win"' : ""}>${path.total.toFixed(1)} <span>${path.spans.map((s) => s.output).join(" + ")}</span></td>`;
const versusHtml = versus
  .map((v) => `<tr><td class="k">…${v.prefix.slice(-6)} まで</td>${pathCell(v.japanese, v.japanese.total >= v.english.total)}${pathCell(v.english, v.english.total > v.japanese.total)}</tr>`)
  .join("");

const html = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<title>tugime conversion</title>
<!-- scripts/make-readme-figures.ts が tugime-cli の出力から生成する。直接編集しない -->
<style>
  :root { --bg0: #0b1020; --ink: #eef2ff; --sub: #9aa4c4; --ja: #8fb8ff; --en: #ffa564; --green: #5fe0a4; --gray: #c3cae3; }
  html, body { margin: 0; width: ${WIDTH}px; height: ${height}px; overflow: hidden; background: var(--bg0); color: var(--ink); font-family: -apple-system, "Hiragino Sans", sans-serif; }
  .wrap { padding: 32px 0 0 0; position: relative; }
  h1 { margin: 0 0 6px 36px; font-size: 22px; }
  .lead { margin: 0 0 18px 36px; font-size: 13px; color: var(--sub); }
  .sec { position: relative; }
  .sec-lbl { position: absolute; left: 36px; top: 0; font-size: 13px; color: var(--sub); }
  .keys { height: 34px; }
  .c { position: absolute; top: 0; width: ${CELL}px; text-align: center; font-family: Menlo, monospace; font-size: 20px; color: #dfe6ff; }
  .head { margin: 0 36px 10px ${AXIS_LEFT}px; font-size: 13px; color: var(--sub); }
  .head b { color: var(--ink); font-size: 14px; margin-right: 10px; }
  .goal { height: 30px; margin-bottom: 8px; }
  .goal .sec-lbl { line-height: 30px; }
  .goal-text { position: absolute; top: 0; line-height: 30px; text-align: center; font-size: 22px; font-weight: 600; white-space: nowrap; }
  .goal-text.J { color: var(--ja); }
  .goal-text.E { color: var(--en); }
  .goal-text.P { color: var(--green); }
  .keys + .head { margin-top: 18px; }
  .lattice { height: ${latticeHeight}px; }
  .ln { position: absolute; height: ${LINE}px; border-radius: 1px; }
  .ln.J { background: rgba(143,184,255,0.55); }
  .ln.E { background: rgba(255,165,100,0.55); }
  .ln.on { height: ${LINE + 2}px; margin-top: -1px; box-shadow: 0 0 0 1px #fff; z-index: 1; }
  .ln.J.on { background: var(--ja); }
  .ln.E.on { background: var(--en); }
  .legend { margin: 12px 0 0 ${AXIS_LEFT}px; font-size: 13px; color: var(--sub); display: flex; gap: 22px; align-items: center; }
  .legend i { display: inline-block; width: 22px; height: 3px; vertical-align: middle; margin-right: 6px; }
  .sep { height: 1px; background: rgba(255,255,255,0.08); margin: 22px 36px; }
  .steps { height: ${stepsHeight}px; }
  .rowlbl { position: absolute; left: 36px; width: ${AXIS_LEFT - 50}px; height: ${BAR}px; line-height: ${BAR}px; text-align: right; font-family: Menlo, monospace; font-size: 13px; color: var(--sub); }
  .bar { position: absolute; height: ${BAR}px; line-height: ${BAR}px; border-radius: 3px; font-size: 15px; font-weight: 600; text-align: center; white-space: nowrap; overflow: hidden; }
  .bar.J { background: rgba(143,184,255,0.22); color: var(--ja); }
  .bar.E { background: rgba(255,165,100,0.22); color: var(--en); }
  .bar.P { background: rgba(95,224,164,0.16); color: var(--green); }
  .vs { margin: 0 0 0 ${AXIS_LEFT}px; border-collapse: collapse; font-size: 14px; }
  .vs th { text-align: left; font-weight: 400; color: var(--sub); font-size: 13px; padding: 0 28px 8px 0; }
  .vs td { padding: 6px 28px 6px 0; color: var(--gray); font-family: Menlo, monospace; }
  .vs td span { font-family: -apple-system, "Hiragino Sans", sans-serif; margin-left: 8px; }
  .vs td.k { color: var(--sub); }
  .vs td.win { color: var(--green); }
</style>
</head>
<body>
<div class="wrap">
  <h1>打鍵列から変換するまで</h1>
  <p class="lead">打鍵のたびに、打鍵列のあらゆる範囲を日本語と英語の両方で読んで点を付け、点の合計が最も高い読み方の並びを採る。</p>

  <div class="sec goal"><span class="sec-lbl">打ちたい文</span>${expectedHtml}</div>
  <div class="sec keys"><span class="sec-lbl">打鍵列</span>${keysHtml}</div>

  <div class="head"><b>比べた読み方</b>線 1 本が、その真上の打鍵を 1 つの区間として読む候補。全 ${placed.length} 本。白く縁取った線が、最後まで打ったときに採った区間</div>
  <div class="sec lattice">${latticeHtml}</div>
  <div class="legend"><span><i style="background:var(--ja)"></i>日本語として読む候補（かな漢字変換の評価値が点）</span><span><i style="background:var(--en)"></i>英語として読む候補（英語の語としてのありそうさが点）</span></div>

  <div class="sep"></div>

  <div class="head"><b>採った読み方</b>打鍵が進むごとに採った区間の並びと、その表示。左は新しく打ったキー</div>
  <div class="sec steps">${stepsHtml}</div>

  <div class="sep"></div>

  <div class="head"><b>最後に入れ替わる理由</b>それぞれの読み方で、最も高い並びの点の合計（高いほうを採る）。表記は点を付けるときの変換</div>
  <table class="vs">
    <tr><th></th><th>全部を日本語として読む</th><th>${flippedWord} を英語として読む</th></tr>
    ${versusHtml}
  </table>
</div>
</body>
</html>
`;

await Bun.write(join(images, "conversion.html"), html);
console.error(`conversion.html 書き出し 区間 ${placed.length} 本、${laneEnds.length} 段 ${elapsed()}`);

async function capture(name: string, pageHeight: number) {
  await step(`${name}.png の書き出し`, () =>
    run([chrome, "--headless", `--screenshot=${join(images, `${name}.png`)}`, `--window-size=${WIDTH},${pageHeight}`, "--force-device-scale-factor=2", "--hide-scrollbars", `file://${join(images, `${name}.html`)}`]),
  );
}
await capture("conversion", height);
await capture("intro", INTRO_HEIGHT);
