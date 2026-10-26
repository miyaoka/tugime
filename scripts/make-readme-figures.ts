// README と docs の図を tugime-cli の出力から作る。
//   docs/images/intro.svg      … 同じ文を打つとき、ふつうの日本語入力と tugime で文字のほかに押すキーを比べる
//   docs/images/conversion.svg … 打鍵列を区切って変換するまで（比べた読み方の候補、打鍵ごとの区切り、最後に入れ替わる理由）
// 使い方: bun install --cwd scripts && bun scripts/make-readme-figures.ts
import { Glyphs, cli, kindOf, prepare, readLive, run, step, svgDocument, writeImage } from "./lib/svg";

const SOURCE = "scripts/make-readme-figures.ts";

// ── intro ─────────────────────────────────────────

/// 紹介の図の打鍵列と、tugime が表示するはずの文
const introInput = "dark mode nohaisyokuwokaete,pull request wodasimasita.";
const introExpected = "dark mode の配色を変えて、pull request を出しました。";

type Token = { key: string } | { text: string } | "space";
/// ime は IME が効いている（かなを変換する）打鍵のまとまり
type Run = { ime: boolean; tokens: Token[] };

const typed = (s: string): Token[] => s.split(" ").flatMap((w, i) => (i === 0 ? [] : ["space" as const]).concat(w ? [{ text: w }] : []));
/// ふつうの日本語入力: 英語を打つたびに英数に切り替え、日本語は Space で変換して Enter で確定する
const plainRuns: Run[] = [
  { ime: false, tokens: [{ key: "英数" }, ...typed("dark mode "), { key: "かな" }] },
  { ime: true, tokens: [{ text: "nohaisyokuwokaete," }, { key: "変換" }, { key: "Enter" }] },
  { ime: false, tokens: [{ key: "英数" }, ...typed("pull request "), { key: "かな" }] },
  { ime: true, tokens: [{ text: "wodasimasita." }, { key: "変換" }, { key: "Enter" }] },
];
/// tugime: 打鍵列をそのまま打ち、最後に Enter で確定する
const tugimeRuns: Run[] = [{ ime: true, tokens: [...typed(introInput), { key: "Enter" }] }];

// 図に並べた打鍵が、紹介する打鍵列と同じかを確かめる。違えば図が別の文を打つことになる
for (const [name, runs] of [["ふつうの日本語入力", plainRuns], ["tugime", tugimeRuns]] as const) {
  const keys = runs.flatMap((r) => r.tokens).map((t) => (t === "space" ? " " : "text" in t ? t.text : "")).join("");
  if (keys !== introInput) throw new Error(`${name} の打鍵 ${keys} が ${introInput} と違う`);
}
const keyCount = (runs: Run[]) => runs.flatMap((r) => r.tokens).filter((t) => t !== "space" && "key" in t).length;

// ── conversion ────────────────────────────────────

/// 変換の図に載せる例文。hide が英語、日本語、英語と入れ替わる
const input = "setteiwohidesitamamanisuru";
/// 最後まで打ったときに表示されるはずの文
const expected = "設定をhideしたままにする";
/// 「採った読み方」に並べる時点（打鍵の数）
const stepEnds = [6, 8, 12, 16, 20, 22, 24, 25, 26];
/// 最後に入れ替わる語と、入れ替わりの前後で比べる時点（打鍵の数）
const flippedWord = "hide";
const versusEnds = [24, 26];
/// 図の筋書き。この時点（打鍵の数）で flippedWord を含む区間がこの種類になる
const flippedKinds: [number, Kind][] = [
  [12, "E"],
  [16, "J"],
  [26, "E"],
];

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
async function readSteps(prefixes: string[], model: string) {
  const explainOut = await run([cli, "--explain", ...prefixes]);
  const explainLines = explainOut.split("\n").filter((l) => /\t[EJP]\[/.test(l));
  if (explainLines.length !== prefixes.length) throw new Error(`--explain の行数 ${explainLines.length} が ${prefixes.length} と合わない`);
  const shown = readLive(await run([cli, "--method", `direct:${model}`, "--live", ...prefixes]), prefixes);
  return prefixes.map((prefix, i) => ({ prefix, segments: parseSegments(explainLines[i].split("\t")[1]), shown: shown[i] }));
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
    // 始まり 終わり 直前の区間の種類 種類 打鍵 出力 点。変換エンジンのログも標準出力に混ざるので、数字とタブで始まる行だけを候補として読む
    if (!/^\d+\t/.test(line)) continue;
    const cols = line.split("\t");
    if (cols.length !== 7) throw new Error(`--lattice の候補の行が 7 列でない: ${line}`);
    if (!current) throw new Error(`== の行より前に候補がある: ${line}`);
    current.push({ s: +cols[0], e: +cols[1], after: cols[2], kind: cols[3] as "J" | "E", output: cols[5], score: +cols[6] });
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

// ── 実行 ──────────────────────────────────────────

const { model, fonts } = await prepare();

const [introShown] = await step("紹介の文の表示", async () => readLive(await run([cli, "--method", `direct:${model}`, "--live", introInput]), [introInput]));
if (introShown !== introExpected) throw new Error(`紹介の文の表示 ${introShown} が ${introExpected} と違う`);

const stepPrefixes = stepEnds.map((end) => input.slice(0, end));
const steps = await step("各時点の区切りと表示", () => readSteps(stepPrefixes, model));
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

// 図の筋書きが出力と合うかを確かめる。合わなければ見出しと説明が偽になる
const [before, after] = versus;
if (!(before.japanese.total > before.english.total)) throw new Error(`${before.prefix} で全部を日本語として読む並びが勝っていない`);
if (!(after.english.total > after.japanese.total)) throw new Error(`${after.prefix} で ${flippedWord} を英語として読む並びが勝っていない`);
for (const [end, kind] of flippedKinds) {
  const s = steps.find((s) => s.prefix.length === end);
  if (!s) throw new Error(`${end} 打鍵の時点が stepEnds に無い`);
  const covering = s.segments.find((seg) => seg.s <= flippedStart && flippedStart < seg.e);
  if (covering?.kind !== kind) throw new Error(`${s.prefix} で ${flippedWord} が ${kind} でなく ${covering?.kind} になっている`);
}

// ── intro.svg ─────────────────────────────────────

{
  const WIDTH = 1000;
  const LEFT = 40;
  const g = new Glyphs(fonts);
  const parts: string[] = [];
  parts.push(g.draw("打ちたい文", "regular", LEFT, 40, 13, "sub"));
  parts.push(g.draw(introExpected, "bold", LEFT, 78, 24, kindOf));

  const TEXT_SIZE = 14;
  const SPACE_W = 10;
  const GAP = 3;
  /// 打鍵の並びを x から描き、終わりの x を返す。y は並びの中央
  const drawRuns = (runs: Run[], x: number, y: number): number => {
    for (const r of runs) {
      const start = x;
      const body: string[] = [];
      for (const t of r.tokens) {
        if (t === "space") {
          body.push(`<rect class="en" opacity="0.35" x="${(x + 1).toFixed(1)}" y="${y - 10}" width="${SPACE_W}" height="20" rx="2"/>`);
          x += SPACE_W + 2;
        } else if ("text" in t) {
          body.push(g.draw(t.text, "bold", x, y + 5, TEXT_SIZE, "ink"));
          x += g.width(t.text, "bold", TEXT_SIZE);
        } else {
          const w = g.width(t.key, "bold", 12) + 14;
          body.push(`<rect class="chip" x="${(x + GAP).toFixed(1)}" y="${y - 12}" width="${w.toFixed(1)}" height="24" rx="6"/>`);
          body.push(g.center(t.key, "bold", x + GAP + w / 2, y + 4.5, 12, "ink"));
          x += w + GAP * 2;
        }
      }
      if (r.ime) parts.push(`<rect class="jtint" x="${(start - 2).toFixed(1)}" y="${y - 17}" width="${(x - start + 4).toFixed(1)}" height="34"/><rect class="line" x="${(start - 2).toFixed(1)}" y="${y + 16}" width="${(x - start + 4).toFixed(1)}" height="2"/>`);
      parts.push(...body);
      x += 4;
    }
    return x;
  };
  const lanes: [string, string, Run[], string][] = [
    ["ふつうの日本語入力", "打っている途中の Space は変換。空白を入れるには英数に切り替える", plainRuns, "bad"],
    ["tugime", "打っている途中の Space は空白。変換は打つそばから自動", tugimeRuns, "good"],
  ];
  const panelTop = 104;
  const laneGap = 92;
  const panelHeight = lanes.length * laneGap + 8;
  parts.push(`<rect class="panel" x="${LEFT - 16}" y="${panelTop}" width="${WIDTH - (LEFT - 16) * 2}" height="${panelHeight}" rx="12"/>`);
  lanes.forEach(([name, rule, runs, countClass], i) => {
    const headY = panelTop + 32 + i * laneGap;
    parts.push(g.draw(name, "bold", LEFT, headY, 15, "ink"));
    parts.push(g.draw(rule, "regular", LEFT + g.width(name, "bold", 15) + 12, headY, 12, "sub"));
    const right = WIDTH - LEFT;
    const tail = " キー";
    const count = String(keyCount(runs));
    parts.push(g.right(tail, "regular", right, headY, 12, "sub"));
    const countRight = right - g.width(tail, "regular", 12);
    parts.push(g.right(count, "bold", countRight, headY, 18, countClass));
    parts.push(g.right("文字のほかに ", "regular", countRight - g.width(count, "bold", 18), headY, 12, "sub"));
    const end = drawRuns(runs, LEFT + 2, headY + 38);
    if (end > WIDTH - LEFT) throw new Error(`${name} の打鍵の並びが幅 ${WIDTH} からはみ出す（${end.toFixed(0)}）`);
  });

  const legendY = panelTop + panelHeight + 34;
  let lx = LEFT;
  const legend = (mark: string, w: number, text: string) => {
    parts.push(mark);
    parts.push(g.draw(text, "regular", lx + w + 8, legendY + 4.5, 12, "sub"));
    lx += w + 8 + g.width(text, "regular", 12) + 28;
  };
  legend(`<rect class="jtint" x="${lx}" y="${legendY - 9}" width="26" height="18"/><rect class="line" x="${lx}" y="${legendY + 8}" width="26" height="2"/>`, 26, "IME が効いている打鍵");
  legend(`<rect class="en" opacity="0.35" x="${lx}" y="${legendY - 10}" width="${SPACE_W}" height="20" rx="2"/>`, SPACE_W, "Space で入れた空白");
  const keyW = g.width("英数", "bold", 12) + 14;
  legend(`<rect class="chip" x="${lx}" y="${legendY - 12}" width="${keyW.toFixed(1)}" height="24" rx="6"/>${g.center("英数", "bold", lx + keyW / 2, legendY + 4.5, 12, "ink")}`, keyW, "文字のほかに押すキー");

  const height = legendY + 30;
  const label = `${introExpected} を打つとき、ふつうの日本語入力では文字のほかに英数・かな・変換・Enter を ${keyCount(plainRuns)} 回押す。tugime では Space がそのまま空白になり、文字のほかに押すのは最後の Enter だけ`;
  await writeImage("intro.svg", svgDocument(SOURCE, WIDTH, height, label, g, parts.join("")));
}

// ── conversion.svg ────────────────────────────────

{
  const WIDTH = 1100;
  const LEFT = 36;
  const CELL = 33;
  const AXIS_LEFT = 196;
  const LINE = 2;
  const LINE_GAP = 1;
  const BAR = 30;
  const ROW_GAP = 10;
  const x = (pos: number) => AXIS_LEFT + pos * CELL;
  const g = new Glyphs(fonts);
  const parts: string[] = [];
  let y = 0;
  const head = (title: string, caption: string) => {
    parts.push(g.draw(title, "bold", AXIS_LEFT, y, 14, "ink"));
    parts.push(g.draw(caption, "regular", AXIS_LEFT + g.width(title, "bold", 14) + 10, y, 12, "sub"));
  };
  const separator = () => {
    y += 22;
    parts.push(`<rect class="chip" x="${LEFT}" y="${y}" width="${WIDTH - LEFT * 2}" height="1"/>`);
    y += 40;
  };
  const segmentClass = (kind: Kind) => (kind === "E" ? "en" : "ink");

  y = 44;
  parts.push(g.draw("打鍵列から変換するまで", "bold", LEFT, y, 20, "ink"));
  y += 26;
  parts.push(g.draw("打鍵のたびに、打鍵列の範囲を日本語や英語として読む候補を挙げて点を付け、点の合計が最も高い読み方の並びを採る。", "regular", LEFT, y, 13, "sub"));

  // 打ちたい文を、区間ごとにその打鍵の範囲の上に置く
  y += 46;
  parts.push(g.draw("打ちたい文", "regular", LEFT, y, 13, "sub"));
  splitShown(finalSegments, finalStep.shown).forEach((text, i) => {
    const s = finalSegments[i];
    parts.push(g.center(text, "bold", (x(s.s) + x(s.e)) / 2, y + 2, 22, segmentClass(s.kind)));
  });
  y += 40;
  parts.push(g.draw("打鍵列", "regular", LEFT, y, 13, "sub"));
  [...input].forEach((c, i) => parts.push(g.center(c, "bold", x(i) + CELL / 2, y, 20, "ink")));

  // 比べた読み方: 区間の候補を、始まりの早い順、長い順に、重ならない段へ詰める
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
  y += 44;
  head("比べた読み方", `線 1 本が真上の打鍵を 1 区間として読む候補（範囲と読み方の組で ${placed.length} 通り）。濃い線は最後に採った区間`);
  y += 16;
  const latticeTop = y;
  for (const p of placed) {
    const on = chosenKeys.has(`${p.s}-${p.e}-${p.kind}`);
    const top = latticeTop + p.lane * (LINE + LINE_GAP) - (on ? 1 : 0);
    parts.push(`<rect class="${segmentClass(p.kind)}" opacity="${on ? 1 : 0.35}" x="${x(p.s) + 1}" y="${top}" width="${(p.e - p.s) * CELL - 2}" height="${on ? LINE + 2 : LINE}"/>`);
  }
  y = latticeTop + laneEnds.length * (LINE + LINE_GAP) + 26;
  let lx = AXIS_LEFT;
  for (const [cls, text] of [["ink", "日本語として読む候補（かな漢字変換の評価値が点）"], ["en", "英語として読む候補（英語の語としてのありそうさが点）"]] as const) {
    parts.push(`<rect class="${cls}" x="${lx}" y="${y - 5}" width="22" height="3"/>`);
    parts.push(g.draw(text, "regular", lx + 30, y, 12, "sub"));
    lx += 30 + g.width(text, "regular", 12) + 28;
  }
  separator();

  // 採った読み方: 打鍵が進むごとに採った区間の並びと、その表示
  head("採った読み方", "打鍵が進むごとに採った区間の並びと、その表示。左は新しく打ったキー");
  y += 14;
  const clips: string[] = [];
  steps.forEach((s, row) => {
    const top = y + row * (BAR + ROW_GAP);
    const previousEnd = row === 0 ? 0 : stepEnds[row - 1];
    parts.push(g.right(`${row === 0 ? "" : "+"}${s.prefix.slice(previousEnd)}`, "bold", AXIS_LEFT - 14, top + BAR / 2 + 5, 13, "sub"));
    const texts = splitShown(s.segments, s.shown);
    s.segments.forEach((seg, i) => {
      const bx = x(seg.s) + 1;
      const bw = (seg.e - seg.s) * CELL - 2;
      const id = `c${row}-${i}`;
      clips.push(`<clipPath id="${id}"><rect x="${bx}" y="${top}" width="${bw}" height="${BAR}"/></clipPath>`);
      parts.push(`<rect class="${seg.kind === "E" ? "etint" : "jtint"}" x="${bx}" y="${top}" width="${bw}" height="${BAR}" rx="3"/>`);
      parts.push(`<g clip-path="url(#${id})">${g.center(texts[i], "bold", bx + bw / 2, top + BAR / 2 + 5.5, 15, segmentClass(seg.kind))}</g>`);
    });
  });
  y += steps.length * (BAR + ROW_GAP) - ROW_GAP;
  separator();

  // 最後に入れ替わる理由
  head("最後に入れ替わる理由", "それぞれの読み方で、最も高い並びの点の合計（高いほうを採る）。表記は点を付けるときの変換");
  const columns = [AXIS_LEFT + 130, AXIS_LEFT + 470];
  y += 32;
  parts.push(g.draw("全部を日本語として読む", "regular", columns[0], y, 12, "sub"));
  parts.push(g.draw(`${flippedWord} を英語として読む`, "regular", columns[1], y, 12, "sub"));
  for (const v of versus) {
    y += 32;
    parts.push(g.draw(`…${v.prefix.slice(-6)} まで`, "regular", AXIS_LEFT, y, 13, "sub"));
    [v.japanese, v.english].forEach((path, i) => {
      const other = i === 0 ? v.english : v.japanese;
      const win = path.total > other.total;
      const score = path.total.toFixed(1);
      parts.push(g.draw(score, "regular", columns[i], y, 14, win ? "good" : "sub"));
      parts.push(g.draw(path.spans.map((s) => s.output).join(" + "), "regular", columns[i] + g.width(score, "regular", 14) + 12, y, 14, win ? "good" : "ink"));
    });
  }
  const height = y + 36;
  const label = `${input} を打ち進めるごとの表示と、その裏で比べた読み方の候補。打鍵列の範囲を日本語や英語として読む候補を挙げ、点の合計が最も高い並びを採る。${flippedWord} は、打った直後は英語、続けて打つと日本語、最後の打鍵で英語に戻る`;
  await writeImage("conversion.svg", svgDocument(SOURCE, WIDTH, height, label, g, `<defs>${clips.join("")}</defs>${parts.join("")}`));
}
