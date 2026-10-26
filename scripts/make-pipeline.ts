// README の変換の仕組みの図 docs/images/pipeline.svg を tugime-cli の出力から作る。
// 打鍵列を工程ごとに形を変える素材として等角投影のコンベアに並べ、各工程で働く部品をキャラにして、この素材に何をしているかを吹き出しで言わせる
// 使い方: bun install --cwd scripts && bun scripts/make-pipeline.ts
import assert from "node:assert";
import {
  type FontName,
  Glyphs,
  type Span,
  assertAlt,
  bestPath,
  cli,
  prepare,
  readExplains,
  readLattices,
  readLive,
  run,
  step,
  svgDocument,
  writeImage,
} from "./lib/svg";

const SOURCE = "scripts/make-pipeline.ts";

/// 図の打鍵列と、採点の変換で採る区切り、最後に表示されるはずの文
const INPUT = "zipwokaitousita.";
const SCORED: [string, string, string] = ["zip", "を回答した", "。"];
const SHOWN = "zipを解凍した。";
/// 工程 3 で比べて捨てる区切り方。[始まり, 終わり, 種類, 出力] の区間が --lattice でつながった並びになるかを確かめる
type RejectedSpan = [number, number, "J" | "E", string];
const REJECTED: [RejectedSpan, RejectedSpan, RejectedSpan] = [
  [0, 2, "J", "次"],
  [2, 3, "E", "p"],
  [3, 15, "J", "を回答した"],
];
/// 同じ「かいとうした」が読みの全体で変わる例。[打鍵列, 表示されるはずの文]
const EXAMPLES: [string, string][] = [
  ["situmonnnikaitousita.", "質問に回答した。"],
  ["tesutonimondaiwokaitousita.", "テストに問題を解答した。"],
];

// ── tugime-cli から値を読む ─────────────────────────

function readingOf(readings: Map<string, string>, input: string): string {
  const reading = readings.get(input);
  assert(reading !== undefined, `--clauses に ${input} が無い`);
  return reading;
}

/// 打鍵列ごとの、日本語の文節の読みをつないだもの（--clauses）
async function readReadings(inputs: string[]): Promise<Map<string, string>> {
  const readings = new Map<string, string>();
  let current: string | undefined;
  for (const line of (await run([cli, "--clauses", ...inputs])).split("\n")) {
    const input = line.match(/^== (\S+)$/)?.[1];
    if (input !== undefined) {
      current = input;
      readings.set(current, "");
      continue;
    }
    // 種類 読み<TAB>候補。変換エンジンのログも標準出力に混ざるので、種類と空白で始まりタブを含む行だけを文節として読む
    const clause = line.match(/^([JEP]) ([^\t]+)\t/);
    if (!clause) continue;
    const [, kind, reading] = clause;
    assert(
      kind !== undefined && reading !== undefined,
      `文節の行を読めない: ${line}`,
    );
    if (current === undefined)
      throw new Error(`== の行より前に文節がある: ${line}`);
    if (kind === "J")
      readings.set(current, readingOf(readings, current) + reading);
  }
  for (const i of inputs)
    if (!readings.get(i))
      throw new Error(`--clauses に日本語の文節が無い: ${i}`);
  return readings;
}

async function readValues(model: string) {
  const [segments] = await readExplains([INPUT]);
  assert(segments !== undefined, `${INPUT} の区切りが無い`);
  const scored = segments.map((s) => s.output);
  assert.deepStrictEqual(
    scored,
    SCORED,
    `採点の区切り ${scored.join("|")} が ${SCORED.join("|")} と違う`,
  );
  const [japanese, ...otherJapanese] = segments.filter((s) => s.kind === "J");
  if (japanese === undefined || otherJapanese.length > 0)
    throw new Error(`日本語の区間が 1 つでない: ${scored.join("|")}`);

  const lattice = (await readLattices([INPUT])).get(INPUT);
  assert(lattice !== undefined, `${INPUT} の区間の候補が無い`);
  const rejectedEnd = REJECTED[2][1];
  const isRejected = (span: Span) =>
    REJECTED.some(
      ([s, e, kind, output]) =>
        span.s === s &&
        span.e === e &&
        span.kind === kind &&
        span.output === output,
    );
  const rejected = bestPath(lattice, rejectedEnd, isRejected);
  if (rejected?.spans.length !== REJECTED.length)
    throw new Error(
      `--lattice で ${REJECTED.map((r) => r[3]).join("｜")} がつながった並びにならない`,
    );
  const japaneseCandidates = lattice.filter((s) => s.kind === "J").length;

  const inputs = [INPUT, ...EXAMPLES.map((e) => e[0])];
  const readings = await readReadings(inputs);
  const shown = readLive(
    await run([cli, "--method", `direct:${model}`, "--live", ...inputs]),
    inputs,
  );
  const expected = [
    { input: INPUT, shown: SHOWN },
    ...EXAMPLES.map(([input, shown]) => ({ input, shown })),
  ];
  assert.deepStrictEqual(shown, expected, "打鍵列の表示が期待する文と違う");
  // 表示は期待する文と一致したので、期待する文を返す
  return {
    scored,
    japaneseKeys: INPUT.slice(japanese.s, japanese.e),
    reading: readingOf(readings, INPUT),
    japaneseCandidates,
    shown: SHOWN,
    examples: EXAMPLES.map(([input, shownExample]) => ({
      reading: readingOf(readings, input),
      shown: shownExample,
    })),
  };
}

// ── 等角投影 ────────────────────────────────────

const W = 1860;
const H = 1490;
const S = 24;
const C = Math.cos(Math.PI / 6);
const OX = 230;
const OY = 640;

type Pt = [number, number];
const P = (x: number, y: number, z = 0): Pt => [
  OX + (x - y) * C * S,
  OY + (x + y) * 0.5 * S - z * S,
];
const pts = (...ps: Pt[]) =>
  ps.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
/// +y 側の面（左下を向く面）に沿わせる変換
const onFront = (p: Pt) =>
  `matrix(${C.toFixed(4)},0.5,0,1,${p[0].toFixed(1)},${p[1].toFixed(1)})`;

function shade(hex: string, f: number): string {
  const n = parseInt(hex.slice(1), 16);
  const t = f < 0 ? 0 : 255;
  const p = Math.abs(f);
  const ch = [n >> 16, (n >> 8) & 255, n & 255].map((c) =>
    Math.round((t - c) * p + c),
  );
  return "#" + ch.map((c) => c.toString(16).padStart(2, "0")).join("");
}

// ── 配色 ──────────────────────────────────────

const INK = "#1e293b";
const SUB = "#64748b";
const EN_INK = "#c2410c";
const JA_INK = "#1d4ed8";
const BAD = "#dc2626";
const GOOD = "#15803d";

const KIND = {
  raw: { col: "#e2e8f0", ink: "#334155" },
  en: { col: "#fdba74", ink: "#7c2d12" },
  ja: { col: "#bfdbfe", ink: "#1e3a8a" },
  pn: { col: "#bbf7d0", ink: "#14532d" },
} as const;
type Kind = keyof typeof KIND;

// ── 文字 ──────────────────────────────────────

/// 1 行の文字の一部。col は文字の色
type Part = { t: string; col: string; font?: FontName };
const T = (t: string, col = INK): Part => ({ t, col });
/// ひらがなをカタカナにする。genmai には読みをカタカナで渡す
const toKatakana = (s: string) =>
  s.replace(/[\u3041-\u3096]/g, (ch) =>
    String.fromCharCode(ch.charCodeAt(0) + 0x60),
  );
const Bold = (t: string, col = INK): Part => ({ t, col, font: "bold" });
const En = (t: string): Part => Bold(t, EN_INK);
const Ja = (t: string): Part => Bold(t, JA_INK);

async function main() {
  const { model, fonts } = await prepare();
  const v = await step("tugime-cli の結果の読み取り", () => readValues(model));
  const g = new Glyphs(fonts);
  const fills = new Set<string>();
  const cls = (col: string) => {
    fills.add(col);
    return `f${col.slice(1)}`;
  };
  const advance = (t: string, font: FontName, size: number) =>
    [...t].reduce((w, ch) => w + g.width(ch, font, size), 0);
  const partsWidth = (parts: Part[], size: number) =>
    parts.reduce((w, p) => w + advance(p.t, p.font ?? "regular", size), 0);
  function text(
    parts: Part[],
    x: number,
    baseline: number,
    size: number,
    anchor: "start" | "middle" | "end" = "start",
  ): string {
    const w = partsWidth(parts, size);
    let cx = anchor === "start" ? x : anchor === "middle" ? x - w / 2 : x - w;
    return parts
      .map((p) => {
        const s = g.draw(
          p.t,
          p.font ?? "regular",
          cx,
          baseline,
          size,
          cls(p.col),
        );
        cx += advance(p.t, p.font ?? "regular", size);
        return s;
      })
      .join("");
  }

  const out: string[] = [];
  const add = (s: string) => out.push(s);

  function box(
    x: number,
    y: number,
    z: number,
    w: number,
    d: number,
    h: number,
    col: string,
  ) {
    const a = `stroke="${shade(col, -0.3)}" stroke-width="1.2" stroke-linejoin="round"`;
    add(
      `<polygon points="${pts(P(x, y + d, z), P(x + w, y + d, z), P(x + w, y + d, z + h), P(x, y + d, z + h))}" fill="${col}" ${a}/>`,
    );
    add(
      `<polygon points="${pts(P(x + w, y, z), P(x + w, y + d, z), P(x + w, y + d, z + h), P(x + w, y, z + h))}" fill="${shade(col, -0.15)}" ${a}/>`,
    );
    add(
      `<polygon points="${pts(P(x, y, z + h), P(x + w, y, z + h), P(x + w, y + d, z + h), P(x, y + d, z + h))}" fill="${shade(col, 0.35)}" ${a}/>`,
    );
  }
  function sparkle(cx: number, cy: number, r: number) {
    add(
      `<path d="M${cx},${cy - r} Q${cx},${cy} ${cx + r},${cy} Q${cx},${cy} ${cx},${cy + r} Q${cx},${cy} ${cx - r},${cy} Q${cx},${cy} ${cx},${cy - r}Z" fill="#f59e0b"/>`,
    );
  }

  // ── 素材の塊 ──
  type Piece = { kind: Kind; parts: Part[] };
  const FS = 22;
  const BY = -0.8;
  const BD = 1.6;
  const BH = 1.45;
  const PAD = 0.9;
  const GAP = 0.35;
  const piece = (kind: Kind, t: string): Piece => ({
    kind,
    parts: [Bold(t, KIND[kind].ink)],
  });
  const pieceLen = (p: Piece) =>
    Math.max(partsWidth(p.parts, FS) / S + PAD, 1.1);
  const rowLen = (pieces: Piece[]) =>
    pieces.reduce((a, p) => a + pieceLen(p) + GAP, -GAP);
  function row(x: number, pieces: Piece[]) {
    const spans: [number, number][] = [];
    for (const p of pieces) {
      const len = pieceLen(p);
      box(x, BY, 0.25, len, BD, BH, KIND[p.kind].col);
      add(
        `<g transform="${onFront(P(x + PAD / 2, BY + BD, 0.25 + BH * 0.3))}">${text(p.parts, 0, 0, FS)}</g>`,
      );
      spans.push([x, x + len]);
      x += len + GAP;
    }
    return spans;
  }

  // 採点の変換と表示の変換で違う字を、それぞれ仮の漢字と書き直した漢字の色にする
  const [en, scoredJa, punct] = v.scored;
  const shownJa = v.shown.slice(en.length, v.shown.length - punct.length);
  if (
    v.shown !== en + shownJa + punct ||
    [...shownJa].length !== [...scoredJa].length
  )
    throw new Error(
      `表示 ${v.shown} を ${v.scored.join("|")} と同じ区切りで比べられない`,
    );
  const diffParts = (word: string, other: string, col: string): Part[] =>
    [...word].map((ch, i) =>
      Bold(ch, ch === [...other][i] ? KIND.ja.ink : col),
    );

  const rowB: Piece[] = [piece("raw", INPUT)];
  const rowC: Piece[] = [
    piece("en", en),
    piece("ja", v.reading),
    piece("raw", INPUT.slice(-1)),
  ];
  const rowD: Piece[] = [
    piece("en", en),
    { kind: "ja", parts: diffParts(scoredJa, shownJa, BAD) },
    piece("pn", punct),
  ];
  const rowE: Piece[] = [
    piece("en", en),
    { kind: "ja", parts: diffParts(shownJa, scoredJa, GOOD) },
    piece("pn", punct),
  ];

  // ── 工程の門 ──
  type Gate = { no: number; x: number; col: string; title: string };
  const GATE_Y0 = -1.7;
  const GATE_Y1 = 1.4;
  const GATE_H = 3.2;
  const GS = 1.0;
  const g1x = 0;
  const bx = g1x + 0.5 + GS;
  const g2x = bx + rowLen(rowB) + GS;
  const cx = g2x + 0.5 + GS;
  const g3x = cx + rowLen(rowC) + GS;
  const dx = g3x + 0.5 + GS;
  const g4x = dx + rowLen(rowD) + GS;
  const ex = g4x + 0.5 + GS;
  const endX = ex + rowLen(rowE) + 1.6;
  const G: [Gate, Gate, Gate, Gate] = [
    { no: 1, x: g1x, col: "#2563eb", title: "受け取る" },
    { no: 2, x: g2x, col: "#2563eb", title: "読み分ける" },
    { no: 3, x: g3x, col: "#2563eb", title: "区切りを決める" },
    { no: 4, x: g4x, col: "#7c3aed", title: "漢字を仕上げる" },
  ];
  const gateBack = (gt: Gate) =>
    box(gt.x, GATE_Y0, 0, 0.5, 0.35, GATE_H, gt.col);
  function gateFront(gt: Gate) {
    box(gt.x, GATE_Y1, 0, 0.5, 0.35, GATE_H, gt.col);
    box(gt.x, GATE_Y0, GATE_H, 0.5, GATE_Y1 + 0.35 - GATE_Y0, 0.45, gt.col);
    add(
      `<polygon points="${pts(P(gt.x + 0.25, GATE_Y0 + 0.35, GATE_H), P(gt.x + 0.25, GATE_Y1, GATE_H), P(gt.x + 0.25, GATE_Y1, 0.25), P(gt.x + 0.25, GATE_Y0 + 0.35, 0.25))}" fill="${gt.col}" opacity="0.10"/>`,
    );
  }
  const gateTop = (gt: Gate) => P(gt.x + 0.25, GATE_Y0, GATE_H + 0.45);
  const gateFoot = (gt: Gate) => P(gt.x + 0.25, GATE_Y1 + 0.35, 0);
  function gatePill(gt: Gate) {
    const a = gateTop(gt);
    const label = [Bold(`${gt.no}  ${gt.title}`, "#ffffff")];
    const w = partsWidth(label, 22) + 34;
    add(
      `<rect x="${a[0] - w / 2}" y="${a[1] - 52}" width="${w}" height="40" rx="20" fill="${gt.col}"/>`,
    );
    add(text(label, a[0], a[1] - 24, 22, "middle"));
  }

  // 塊から線を引いて、通り道の手前に添える注記
  function note(x: number, label: string, col: string) {
    const p = P(x + 1.5, 2.2, 0);
    const b = P(x, BY + BD, 0.25);
    add(
      `<line x1="${b[0]}" y1="${b[1]}" x2="${p[0] + 6}" y2="${p[1] + 12}" stroke="${col}" stroke-width="1.5" opacity="0.6"/>`,
    );
    add(text([Bold(label, col)], p[0], p[1] + 26, 18, "end"));
  }

  // ── 通り道と素材 ──
  add(
    `<polygon points="${pts(P(-6, -2.2), P(endX, -2.2), P(endX, 2.2), P(-6, 2.2))}" fill="#e2e8f0"/>`,
  );
  for (let x = -5; x < endX; x += 1.6) {
    const a = P(x, 1.85);
    add(
      `<path d="M0,-4 L7,0 L0,4 Z" fill="#94a3b8" transform="${onFront(a)}"/>`,
    );
  }
  for (const gt of G) gateBack(gt);
  {
    const keys = [...INPUT.slice(0, 7)];
    const a = P(-5.5, 0, 0.6);
    const b = P(0, 0, 1.2);
    const n = keys.length + 1;
    keys.forEach((k, i) => {
      const t = i / (n - 1);
      const x = a[0] + (b[0] - a[0]) * t;
      const y = a[1] + (b[1] - a[1]) * t - Math.sin(t * Math.PI) * 40;
      add(
        `<g transform="translate(${x.toFixed(1)},${y.toFixed(1)}) rotate(${-10 + i * 4})"><rect x="-15" y="-15" width="30" height="30" rx="6" fill="#fff" stroke="#94a3b8" stroke-width="1.5"/><rect x="-15" y="10" width="30" height="6" rx="3" fill="#cbd5e1"/>${text([En(k)], 0, 6, 17, "middle")}</g>`,
      );
    });
    for (let i = 0; i < 3; i++)
      add(
        `<circle cx="${(b[0] - 14 + i * 7).toFixed(1)}" cy="${(b[1] - 4).toFixed(1)}" r="2" fill="${EN_INK}"/>`,
      );
  }
  const [rawSpan] = row(bx, rowB);
  gateFront(G[0]);
  const [enSpan, readingSpan] = row(cx, rowC);
  gateFront(G[1]);
  const [, scoredSpan] = row(dx, rowD);
  gateFront(G[2]);
  const [, shownSpan] = row(ex, rowE);
  gateFront(G[3]);
  assert(
    rawSpan && enSpan && readingSpan && scoredSpan && shownSpan,
    "素材の行の塊が足りない",
  );

  const mid = (s: [number, number]) => (s[0] + s[1]) / 2;
  add(text([Bold("打鍵（キー 1 つずつ）", SUB)], 24, P(-4.5, 2.2)[1] + 74, 18));
  note(mid(rawSpan), "まだ 1 本の打鍵列", SUB);
  note(mid(enSpan), "読めない → 英語", EN_INK);
  note(mid(readingSpan), "かなに読める", JA_INK);
  {
    const p = P(mid(scoredSpan), BY, 0.25 + BH);
    add(
      text(
        [Bold("区切りは決定。漢字はまだ仮", BAD)],
        p[0] + 10,
        p[1] - 62,
        18,
        "middle",
      ),
    );
    const s = shownSpan;
    const q = P(s[1], BY, 0.25 + BH);
    sparkle(q[0] - 4, q[1] - 14, 10);
    sparkle(q[0] + 14, q[1] + 4, 6);
    const r = P(s[0] + 0.6, BY, 0.25 + BH);
    sparkle(r[0], r[1] - 8, 7);
  }

  // ── 出荷先: アプリの入力欄 ──
  {
    const p = P(endX, 0, 0.9);
    const x = W - 480;
    const y = 1030;
    add(
      `<path d="M${p[0] - 30},${p[1] + 10} Q${p[0] + 40},${p[1] - 20} ${x + 220},${y + 172}" fill="none" stroke="#475569" stroke-width="2.5" marker-end="url(#ar)"/>`,
    );
    add(
      `<rect x="${x}" y="${y}" width="440" height="170" rx="12" fill="#fff" stroke="#cbd5e1" stroke-width="1.5" filter="url(#sh)"/>`,
    );
    add(
      `<rect x="${x}" y="${y}" width="440" height="40" rx="12" fill="#f1f5f9"/><rect x="${x}" y="${y + 28}" width="440" height="12" fill="#f1f5f9"/>`,
    );
    add(
      `<circle cx="${x + 22}" cy="${y + 20}" r="6" fill="#f87171"/><circle cx="${x + 42}" cy="${y + 20}" r="6" fill="#fbbf24"/><circle cx="${x + 62}" cy="${y + 20}" r="6" fill="#4ade80"/>`,
    );
    add(text([T("アプリの入力欄に表示", SUB)], x + 82, y + 27, 18));
    const shown = [Bold(en, EN_INK), Bold(v.shown.slice(en.length), "#0f172a")];
    add(text(shown, x + 28, y + 104, 44));
    add(
      `<line x1="${x + 28}" y1="${y + 118}" x2="${x + 28 + partsWidth(shown, 44)}" y2="${y + 118}" stroke="#0f172a" stroke-width="2" stroke-dasharray="5 4"/>`,
    );
    add(text([T("未確定。Enter で確定", SUB)], x + 28, y + 146, 16));
  }

  // ── 部品のキャラ ──
  type Bot = { col: string; name: string; sub: string; prop: string };
  const K = 1.35;
  function robot(x: number, y: number, b: Bot) {
    const hd = shade(b.col, 0.3);
    const dk = shade(b.col, -0.35);
    add(
      `<g transform="translate(${x},${y}) scale(${K}) translate(${-x},${-y})">`,
    );
    add(
      `<ellipse cx="${x}" cy="${y}" rx="32" ry="7" fill="#0f172a" opacity="0.1"/>`,
    );
    add(
      `<rect x="${x - 15}" y="${y - 18}" width="11" height="18" rx="4" fill="${dk}"/><rect x="${x + 4}" y="${y - 18}" width="11" height="18" rx="4" fill="${dk}"/>`,
    );
    add(
      `<path d="M${x - 24},${y - 46} Q${x - 40},${y - 34} ${x - 34},${y - 22}" fill="none" stroke="${dk}" stroke-width="7" stroke-linecap="round"/>`,
    );
    add(
      `<rect x="${x - 25}" y="${y - 58}" width="50" height="44" rx="12" fill="${b.col}" stroke="${dk}" stroke-width="1.5"/>`,
    );
    add(
      `<rect x="${x - 14}" y="${y - 48}" width="28" height="14" rx="4" fill="${hd}"/>`,
    );
    add(
      `<line x1="${x}" y1="${y - 106}" x2="${x}" y2="${y - 120}" stroke="${dk}" stroke-width="3"/><circle cx="${x}" cy="${y - 122}" r="6" fill="#facc15" stroke="${dk}" stroke-width="1.5"/>`,
    );
    add(
      `<rect x="${x - 32}" y="${y - 108}" width="64" height="50" rx="16" fill="${hd}" stroke="${dk}" stroke-width="1.5"/>`,
    );
    add(
      `<rect x="${x - 24}" y="${y - 100}" width="48" height="33" rx="10" fill="#0f172a"/>`,
    );
    add(
      `<circle cx="${x - 10}" cy="${y - 86}" r="4.5" fill="#67e8f9"/><circle cx="${x + 10}" cy="${y - 86}" r="4.5" fill="#67e8f9"/>`,
    );
    add(
      `<path d="M${x - 7},${y - 76} Q${x},${y - 71} ${x + 7},${y - 76}" fill="none" stroke="#67e8f9" stroke-width="2" stroke-linecap="round"/>`,
    );
    add(`<g transform="translate(${x + 30},${y - 44})">${b.prop}</g>`);
    add(
      `<path d="M${x + 24},${y - 46} Q${x + 34},${y - 46} ${x + 34},${y - 40}" fill="none" stroke="${dk}" stroke-width="7" stroke-linecap="round"/>`,
    );
    add(text([Bold(b.name, dk)], x, y + 22, 15, "middle"));
    add(text([T(b.sub, SUB)], x, y + 39, 11, "middle"));
    add(`</g>`);
  }

  const BFS = 22;
  const bubbleWidth = (lines: Part[][]) =>
    Math.max(...lines.map((l) => partsWidth(l, BFS))) + 40;
  /// 吹き出し。tail は口元の座標
  function bubble(
    x: number,
    y: number,
    lines: Part[][],
    col: string,
    tail: Pt,
  ) {
    const lh = 32;
    const w = bubbleWidth(lines);
    const h = lines.length * lh + 22;
    const side = tail[0] < x ? "l" : "r";
    const edge = side === "l" ? x + 1 : x + w - 1;
    const t = `${edge},${y + h / 2 - 10} ${tail[0]},${tail[1]} ${edge},${y + h / 2 + 10}`;
    add(
      `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="14" fill="#fff" stroke="${col}" stroke-width="2" filter="url(#sh)"/>`,
    );
    add(
      `<polygon points="${t}" fill="#fff" stroke="${col}" stroke-width="2" stroke-linejoin="round"/>`,
    );
    add(
      `<polygon points="${t}" fill="#fff" transform="translate(${side === "l" ? 2.5 : -2.5},0)"/>`,
    );
    lines.forEach((l, i) => add(text(l, x + 20, y + 38 + i * lh, BFS)));
  }
  const worksAt = (from: Pt, to: Pt, col: string) =>
    add(
      `<line x1="${from[0]}" y1="${from[1]}" x2="${to[0]}" y2="${to[1]}" stroke="${col}" stroke-width="2" stroke-dasharray="2 5" stroke-linecap="round"/>`,
    );
  const mouthR = (r: Pt): Pt => [r[0] + 44, r[1] - 120];
  const mouthL = (r: Pt): Pt => [r[0] - 44, r[1] - 112];
  /// 通り道の奥に立ち、右に吹き出しを出す
  function back(
    a: Pt,
    off: Pt,
    bot: Bot,
    lines: Part[][],
    col: string,
    dy = -175,
  ) {
    const r: Pt = [a[0] + off[0], a[1] + off[1]];
    worksAt([r[0] - 30, r[1]], [a[0] + 10, a[1] - 14], col);
    robot(r[0], r[1], bot);
    bubble(r[0] + 80, r[1] + dy, lines, col, mouthR(r));
  }
  /// 通り道の手前に立ち、左に吹き出しを出す
  function front(
    f: Pt,
    off: Pt,
    bot: Bot,
    lines: Part[][],
    col: string,
    dy = -190,
  ) {
    const r: Pt = [f[0] + off[0], f[1] + off[1]];
    worksAt([r[0] + 10, r[1] - 170], [f[0] - 4, f[1] + 4], col);
    robot(r[0], r[1], bot);
    bubble(r[0] - 95 - bubbleWidth(lines), r[1] + dy, lines, col, mouthL(r));
  }

  const glyph = (
    t: string,
    x: number,
    y: number,
    size: number,
    col: string,
    font: FontName = "bold",
  ) => text([{ t, col, font }], x, y, size, "middle");
  const [firstKey] = INPUT;
  assert(firstKey !== undefined, "INPUT が空");
  const PROP = {
    key: `<rect x="-2" y="-16" width="26" height="26" rx="5" fill="#fff" stroke="#94a3b8" stroke-width="1.5"/>${glyph(firstKey, 11, 3, 15, EN_INK)}`,
    table: `<rect x="-4" y="-22" width="40" height="34" rx="3" fill="#fff" stroke="#16a34a" stroke-width="1.5"/><line x1="-4" y1="-11" x2="36" y2="-11" stroke="#86efac"/><line x1="-4" y1="0" x2="36" y2="0" stroke="#86efac"/><line x1="14" y1="-22" x2="14" y2="12" stroke="#86efac"/>`,
    dict: `<rect x="-2" y="-22" width="30" height="36" rx="3" fill="#0d9488"/><rect x="2" y="-18" width="22" height="28" rx="2" fill="#ccfbf1"/>${glyph("辞書", 13, -3, 9, "#115e59")}`,
    bars: `<rect x="-2" y="-22" width="40" height="36" rx="4" fill="#fff" stroke="#d97706" stroke-width="1.5"/><rect x="4" y="-2" width="6" height="12" fill="#f59e0b"/><rect x="13" y="-14" width="6" height="24" fill="#f59e0b"/><rect x="22" y="-8" width="6" height="18" fill="#f59e0b"/>`,
    scale: `<line x1="14" y1="-26" x2="14" y2="12" stroke="#334155" stroke-width="2.5"/><line x1="-6" y1="-18" x2="34" y2="-24" stroke="#334155" stroke-width="2.5"/><path d="M-14,-6 Q-6,2 2,-6 Z" fill="#22c55e"/><path d="M26,-12 Q34,-4 42,-12 Z" fill="#ef4444"/><line x1="-6" y1="-18" x2="-14" y2="-6" stroke="#334155"/><line x1="-6" y1="-18" x2="2" y2="-6" stroke="#334155"/><line x1="34" y1="-24" x2="26" y2="-12" stroke="#334155"/><line x1="34" y1="-24" x2="42" y2="-12" stroke="#334155"/>`,
    pen: `<rect x="-4" y="-20" width="38" height="30" rx="3" fill="#fff" stroke="#9333ea" stroke-width="1.5"/>${glyph(shownJa.slice(1, 3), 15, 0, 12, GOOD)}<path d="M30,-30 L40,-22 L22,0 L14,4 L16,-6 Z" fill="#a855f7" stroke="#6b21a8"/>`,
    chip: `<rect x="0" y="-20" width="30" height="30" rx="4" fill="#1f2937"/>${glyph("GPU", 15, -1, 9, "#fb923c")}<path d="M5,-24 v4 M12,-24 v4 M19,-24 v4 M26,-24 v4 M5,10 v4 M12,10 v4 M19,10 v4 M26,10 v4" stroke="#facc15" stroke-width="2"/>`,
  };

  for (const gt of G) gatePill(gt);
  const rejected = REJECTED.map((r) => r[3]).join("｜") + `｜${punct}`;
  /// 例の表示のうち「した」の前の 2 字（読みで変わる漢字）を書き直した漢字の色にする
  const example = (reading: string, shown: string): Part[] => {
    const word = shown.replace(/。$/, "");
    const at = word.lastIndexOf("した") - 2;
    if (at < 0 || !/^\p{Script=Han}{2}$/u.test(word.slice(at, at + 2)))
      throw new Error(`例 ${shown} に「した」の前の漢字 2 字が無い`);
    return [
      T(`${reading} → ${word.slice(0, at)}`),
      Bold(word.slice(at, at + 2), GOOD),
      T(word.slice(at + 2)),
    ];
  };

  back(
    gateTop(G[0]),
    [120, -110],
    {
      col: "#94a3b8",
      name: "InputMethodKit",
      sub: "Apple（macOS の入力の仕組み）",
      prop: PROP.key,
    },
    [
      [T("キーが届いたよ: "), En([...INPUT.slice(0, 5)].join(" ") + " …")],
      [T("入力欄のカーソルの前の文は空っぽ")],
      [T("出来上がった文字列は入力欄に出しておく")],
    ],
    "#64748b",
    -160,
  );
  back(
    gateTop(G[1]),
    [120, -110],
    {
      col: "#4ade80",
      name: "ローマ字の綴りの表",
      sub: "Mozc から借りた表",
      prop: PROP.table,
    },
    [
      [En(v.japaneseKeys), T(" は "), Ja(v.reading), T(" と読める")],
      [
        En(en),
        T(" は "),
        En(REJECTED[1][3]),
        T(" が表に無いから、かなにできない"),
      ],
    ],
    "#16a34a",
  );
  back(
    gateTop(G[2]),
    [110, -120],
    {
      col: "#2dd4bf",
      name: "システム辞書",
      sub: "Mozc から借りた辞書と品詞の連接",
      prop: PROP.dict,
    },
    [
      [Ja(v.reading), T(" なら "), Ja(scoredJa)],
      [T("日本語としての自然さを点にして返すよ")],
      [T("検査係が区切り方の候補ごとに聞いてくる。")],
      [T(`この打鍵列なら日本語の候補 ${v.japaneseCandidates} 個に点を付ける`)],
    ],
    "#0d9488",
    -215,
  );
  back(
    gateTop(G[2]),
    [400, 30],
    {
      col: "#fbbf24",
      name: "wordfreq・Webster's",
      sub: "英語の語の頻度と語表",
      prop: PROP.bars,
    },
    [
      [En(en), T(" は日本語の文の中でも英字のまま")],
      [T("よく書かれる語。英語としての点を返すよ")],
    ],
    "#d97706",
  );
  front(
    gateFoot(G[2]),
    [-60, 170],
    {
      col: "#3b82f6",
      name: "tugime の検査係",
      sub: "tugime 自身",
      prop: PROP.scale,
    },
    [
      [T("区切り方ごとに点を足して比べる")],
      [En(en), T("｜"), Ja(scoredJa), T("｜"), Ja(punct), T(" が最高点")],
      [T(rejected, BAD), T(" は捨てる")],
    ],
    "#2563eb",
  );
  front(
    gateFoot(G[3]),
    [-110, 200],
    { col: "#c084fc", name: "genmai-310M", sub: "変換モデル", prop: PROP.pen },
    [
      [T("前の文は "), En(en), T("、読みは "), Ja(toKatakana(v.reading))],
      [
        T("続きを書くなら "),
        ...diffParts(shownJa, scoredJa, GOOD).map((p) =>
          p.col === KIND.ja.ink ? Bold(p.t) : p,
        ),
      ],
      ...v.examples.map((e) => example(e.reading, e.shown)),
    ],
    "#9333ea",
    -60,
  );
  {
    const f = gateFoot(G[3]);
    const r: Pt = [f[0] + 130, f[1] + 270];
    worksAt([r[0] - 10, r[1] - 170], [f[0] + 4, f[1] + 4], "#ea580c");
    robot(r[0], r[1], {
      col: "#fb923c",
      name: "llama.cpp",
      sub: "モデルを動かすエンジン",
      prop: PROP.chip,
    });
    bubble(
      r[0] + 80,
      r[1] - 150,
      [
        [T("genmai を Mac の GPU で動かす係")],
        [T("前の打鍵の計算を使い回して、")],
        [T("次のキーが来る前に書き終える")],
      ],
      "#ea580c",
      mouthR(r),
    );
  }

  // ── 見出し ──
  add(text([Bold("打鍵が文になるまで", "#0f172a")], 40, 60, 42));
  add(
    text(
      [
        En(INPUT),
        T(" と打ったとき、素材がどう変わり、誰が何をしているか", "#475569"),
      ],
      42,
      102,
      22,
    ),
  );
  add(
    text(
      [T("1 キー打つたびに、打鍵列の全部を最初から流し直す", SUB)],
      42,
      136,
      18,
    ),
  );
  (
    [
      ["raw", "打鍵"],
      ["en", "英語"],
      ["ja", "日本語"],
      ["pn", "句読点"],
    ] as const
  ).forEach(([k, label], i) => {
    const x = 44 + i * 110;
    add(
      `<rect x="${x}" y="154" width="20" height="20" rx="4" fill="${KIND[k].col}" stroke="${shade(KIND[k].col, -0.3)}"/>`,
    );
    add(text([T(label, "#334155")], x + 28, 171, 17));
  });

  const defs = `<defs><filter id="sh" x="-10%" y="-10%" width="120%" height="140%"><feDropShadow dx="0" dy="3" stdDeviation="5" flood-color="#0f172a" flood-opacity="0.10"/></filter><marker id="ar" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 Z" fill="#475569"/></marker></defs>`;
  const style = [...fills]
    .map((c) => `\n  .f${c.slice(1)} { fill: ${c}; }`)
    .join("");
  const label = `${INPUT} と打ったときの tugime の工程。1 受け取る、2 読み分ける（${en} は読めないので英語）、3 区切りを決める（${v.scored.join("｜")}）、4 漢字を仕上げる（${v.shown}）。各工程では InputMethodKit、ローマ字の綴りの表、システム辞書、wordfreq と Webster's、tugime の検査係、genmai-310M、llama.cpp が働く`;
  await assertAlt("README.md", "pipeline.svg", [
    INPUT,
    v.scored.join("｜"),
    v.shown,
  ]);
  await writeImage(
    "pipeline.svg",
    svgDocument(SOURCE, W, H, label, g, defs + out.join(""), "light", style),
  );
}

await main();
