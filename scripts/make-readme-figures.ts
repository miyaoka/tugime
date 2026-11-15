// README と docs の図を tugime-cli の出力から作る。
//   docs/images/intro.svg      … 同じ文を打つとき、一般的な日本語入力と tugime で文字のほかに押すキーを比べる
//   docs/images/context.svg    … 同じ読みの前の語だけを変えたとき、tugime の表記が前の語に合わせて変わる
//   docs/images/conversion.svg … 打鍵列を区切って変換するまで（比べた読み方の候補、打鍵ごとの区切り、英語の語を英語として読む理由）
// 使い方: bun install --cwd scripts && bun scripts/make-readme-figures.ts
import assert from "node:assert";
import {
  Glyphs,
  type Kind,
  type Segment,
  type Span,
  assertAlt,
  bestPath,
  cli,
  kindOf,
  prepare,
  readExplains,
  readLattices,
  readPerInput,
  run,
  step,
  svgDocument,
  writeImage,
} from "./lib/svg";

const SOURCE = "scripts/make-readme-figures.ts";

// ── intro ─────────────────────────────────────────

/// 紹介の図の打鍵列と、tugime が表示するはずの文
const introInput = "dark mode nohaisyokuwokaete,pull request wodasimasita.";
const introExpected = "dark mode の配色を変えて、pull request を出しました。";

/// 打ちたい文の語のまとまり。typed はその打鍵、shown は表示される文字列。図では打鍵ではなく表示を帯に書く
type Piece = { typed: string; shown: string; kind: "en" | "ja" };
const pieces = {
  darkMode: { typed: "dark mode ", shown: "dark mode ", kind: "en" },
  haishoku: {
    typed: "nohaisyokuwokaete,",
    shown: "の配色を変えて、",
    kind: "ja",
  },
  pullRequest: { typed: "pull request ", shown: "pull request ", kind: "en" },
  dashita: { typed: "wodasimasita.", shown: "を出しました。", kind: "ja" },
} satisfies Record<string, Piece>;
/// 1 行に並べるもの。文字列は文字のほかに押すキー
type Lane = (Piece | string)[];

/// 一般的な日本語入力: 英語を打つたびに英数に切り替え、日本語は Space で変換して Enter で確定する。Mac のキーボードに変換キーは無い
const plainLanes: Lane[] = [
  ["英数", pieces.darkMode, "かな", pieces.haishoku, "Space", "Enter"],
  ["英数", pieces.pullRequest, "かな", pieces.dashita, "Space", "Enter"],
];
/// tugime: 打鍵列をそのまま打ち、最後に Enter で確定する
const tugimeLanes: Lane[] = [
  [
    pieces.darkMode,
    pieces.haishoku,
    pieces.pullRequest,
    pieces.dashita,
    "Enter",
  ],
];

// 図に並べた打鍵と表示が、紹介する打鍵列と表示と同じかを確かめる。違えば図が別の文を打つことになる
for (const [name, lanes] of [
  ["一般的な日本語入力", plainLanes],
  ["tugime", tugimeLanes],
] as const) {
  const ps = lanes.flat().filter((t): t is Piece => typeof t !== "string");
  const keys = ps.map((p) => p.typed).join("");
  if (keys !== introInput)
    throw new Error(`${name} の打鍵 ${keys} が ${introInput} と違う`);
  const shown = ps.map((p) => p.shown).join("");
  if (shown !== introExpected)
    throw new Error(`${name} の表示 ${shown} が ${introExpected} と違う`);
}
const keyCount = (lanes: Lane[]) =>
  lanes.flat().filter((t) => typeof t === "string").length;

// ── context ───────────────────────────────────────

/// 自動変換の図の打鍵列。同じ読み ひいている の前の語だけを変える
const contextInputs = [
  "pianowohiiteiru.",
  "tunawohiiteiru.",
  "kazewohiiteiru.",
];
/// 表示を、前の語、を、ひいて の表記、残り（いる。）に分ける
function splitContext(shown: string): {
  word: string;
  particle: string;
  verb: string;
  after: string;
} {
  const i = shown.indexOf("を");
  const j = shown.lastIndexOf("いる。");
  if (i <= 0 || j <= i + 1)
    throw new Error(`表示 ${shown} を 〜を〜いる。 に分けられない`);
  return {
    word: shown.slice(0, i),
    particle: "を",
    verb: shown.slice(i + 1, j),
    after: shown.slice(j),
  };
}

// ── conversion ────────────────────────────────────

/// 変換の図に載せる例文。youtube が英語、日本語（ようつべ）、英語と入れ替わる
const input = "kinouhayoutubewomiteita";
/// 最後まで打ったときに表示されるはずの文
const expected = "昨日はyoutubeを見ていた";
/// 「採った読み方」に並べる時点（打鍵の数）
const stepEnds = [5, 7, 12, 14, 15, 16, 20, 23];
/// 日本語としても読める英語の語。最後まで打ったときに、英語として読む並びと全部を日本語として読む並びの点を比べる
const englishWord = "youtube";
/// englishWord が日本語として読まれる時点（打鍵の数）と、そのときの表示に含まれる englishWord の日本語の表記。次の打鍵で英語に戻る
const japaneseWordAt = 15;
const japaneseWord = "ようつべ";
/// 図の筋書き。この時点（打鍵の数）で englishWord を含む区間がこの種類になる
const wordKinds: [number, Kind][] = [
  [japaneseWordAt - 1, "E"],
  [japaneseWordAt, "J"],
  [japaneseWordAt + 1, "E"],
  [input.length, "E"],
];

/// 打鍵列の途中までごとの、区切り（--explain）と表示（--live）
async function readSteps(prefixes: string[], model: string) {
  const segments = await readExplains(prefixes);
  const shown = readPerInput(
    "--live",
    await run([cli, "--method", `direct:${model}`, "--live", ...prefixes]),
    prefixes,
  );
  // readExplains は渡した打鍵列と同じ順に、同じ数の区切りを返す
  return shown.map(({ input: prefix, result: shown }, i) => {
    const s = segments[i];
    assert(s !== undefined, `${prefix} の区切りが無い`);
    return { prefix, segments: s, shown };
  });
}

/// 表示の文字列を区間ごとに分け、区間と組にする。英語と句読点の区間は出力がそのまま表示に出るので、その間を日本語の区間の表示とする
function splitShown(
  segments: Segment[],
  shown: string,
): { segment: Segment; text: string }[] {
  let cursor = 0;
  return segments.map((segment, i) => {
    if (segment.kind !== "J") {
      if (!shown.startsWith(segment.output, cursor))
        throw new Error(
          `表示 ${shown} の ${cursor} 文字目に ${segment.output} が無い`,
        );
      cursor += segment.output.length;
      return { segment, text: segment.output };
    }
    const next = segments.slice(i + 1).find((s) => s.kind !== "J");
    const end = next ? shown.indexOf(next.output, cursor) : shown.length;
    if (next && end < 0)
      throw new Error(`表示 ${shown} に ${next.output} が無い`);
    const text = shown.slice(cursor, end);
    cursor = end;
    return { segment, text };
  });
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

const [intro] = await step("紹介の文の表示", async () =>
  readPerInput(
    "--live",
    await run([cli, "--method", `direct:${model}`, "--live", introInput]),
    [introInput],
  ),
);
const introShown = intro?.result;
if (introShown !== introExpected)
  throw new Error(`紹介の文の表示 ${introShown} が ${introExpected} と違う`);

const contextRows = await step("自動変換の文の表示", async () => {
  const shown = readPerInput(
    "--live",
    await run([cli, "--method", `direct:${model}`, "--live", ...contextInputs]),
    contextInputs,
  );
  return contextInputs.map((input, i) => {
    const s = shown[i];
    assert(s !== undefined, `${input} の表示が無い`);
    const at = input.indexOf("wo");
    if (at <= 0) throw new Error(`${input} に前の語の打鍵が無い`);
    const typedWord = input.slice(0, at);
    return { input, typedWord, ...splitContext(s.result) };
  });
});
// 図の筋書き: 同じ ひいて が、前の語ごとに違う表記になる
const contextVerbs = new Set(contextRows.map((r) => r.verb));
if (contextVerbs.size !== contextRows.length)
  throw new Error(
    `ひいて の表記に同じものがある: ${contextRows.map((r) => r.verb).join(" / ")}`,
  );

const stepPrefixes = stepEnds.map((end) => input.slice(0, end));
const steps = await step("各時点の区切りと表示", () =>
  readSteps(stepPrefixes, model),
);
const lattices = await step("区間の候補", () => readLattices([input]));

const lattice = lattices.get(input);
assert(lattice !== undefined, `${input} の区間の候補が無い`);
const chosen = bestPath(lattice, input.length, () => true);
if (!chosen) throw new Error("最後まで打ったときの並びが見つからない");
const finalStep = steps.at(-1);
assert(finalStep !== undefined, "stepEnds が空");
if (finalStep.prefix !== input)
  throw new Error(`最後の時点 ${finalStep.prefix} が打鍵列の全体ではない`);
if (finalStep.shown !== expected)
  throw new Error(
    `最後まで打ったときの表示 ${finalStep.shown} が期待する文 ${expected} と違う`,
  );
const finalSegments = finalStep.segments;
if (mergedBounds(chosen.spans) !== mergedBounds(finalSegments)) {
  throw new Error(
    `候補から求めた並び ${mergedBounds(chosen.spans)} が --explain の ${mergedBounds(finalSegments)} と合わない`,
  );
}
const chosenKeys = new Set(chosen.spans.map((s) => `${s.s}-${s.e}-${s.kind}`));

const wordStart = input.indexOf(englishWord);
if (wordStart < 0) throw new Error(`${englishWord} が ${input} に無い`);
const isEnglishWord = (s: Span) =>
  s.kind === "E" && s.s === wordStart && s.e === wordStart + englishWord.length;
const japanese = bestPath(lattice, input.length, (s) => s.kind === "J");
const english = bestPath(lattice, input.length, () => true, isEnglishWord);
if (!japanese || !english)
  throw new Error(`比べる並びが見つからない: ${input}`);

// 図の筋書きが出力と合うかを確かめる。合わなければ見出しと説明が偽になる
if (!(english.total > japanese.total))
  throw new Error(
    `${input} で ${englishWord} を英語として読む並びが勝っていない`,
  );
if (!chosen.spans.some(isEnglishWord))
  throw new Error(
    `${input} の採った並びに ${englishWord} だけの英語の区間が無い`,
  );
const japaneseWordStep = steps.find((s) => s.prefix.length === japaneseWordAt);
if (!japaneseWordStep?.shown.includes(japaneseWord))
  throw new Error(
    `${japaneseWordAt} 打鍵の時点の表示 ${japaneseWordStep?.shown} に ${japaneseWord} が無い`,
  );
for (const [end, kind] of wordKinds) {
  const s = steps.find((s) => s.prefix.length === end);
  if (!s) throw new Error(`${end} 打鍵の時点が stepEnds に無い`);
  const covering = s.segments.find(
    (seg) => seg.s <= wordStart && wordStart < seg.e,
  );
  if (covering?.kind !== kind)
    throw new Error(
      `${s.prefix} で ${englishWord} が ${kind} でなく ${covering?.kind} になっている`,
    );
}

// ── intro.svg ─────────────────────────────────────

{
  const WIDTH = 1100;
  const LEFT = 48;
  const PAD = 24;
  /// 行の名前と回数を置く列の幅
  const HEAD_W = 180;
  const ROW = 44;
  const ROW_GAP = 12;
  const GAP = 8;
  const PANEL_H = 152;
  const PANEL_GAP = 16;
  const KEY_SIZE = 19;
  const BAR_SIZE = 17;
  /// キーキャップの下に見せる厚み
  const KEY_DEPTH = 4;
  /// キーキャップの面と縁、帯に書く表示の色。帯の地は .etint / .jtint
  const STYLE = `
  .keyface { fill: #ffffff; } .keyedge { fill: #374151; } .enmute { fill: #c08457; } .jamute { fill: #8a96a8; }
  @media (prefers-color-scheme: dark) {
    .keyface { fill: #21262d; } .keyedge { fill: #8b949e; } .enmute { fill: #c98a5c; } .jamute { fill: #8b949e; }
  }`;

  const g = new Glyphs(fonts);
  const parts: string[] = [];
  parts.push(g.draw("打ちたい文", "regular", LEFT, 48, 15, "sub"));
  parts.push(g.draw(introExpected, "bold", LEFT, 96, 30, kindOf));

  /// 文字のほかに押すキーを、キーキャップの形で x に描き、幅を返す
  const drawKey = (key: string, x: number, top: number): number => {
    const w = Math.max(70, g.width(key, "bold", KEY_SIZE) + 28);
    parts.push(
      `<rect class="keyedge" x="${x.toFixed(1)}" y="${top + KEY_DEPTH}" width="${w.toFixed(1)}" height="${ROW}" rx="8"/>`,
      `<rect class="keyedge" x="${x.toFixed(1)}" y="${top}" width="${w.toFixed(1)}" height="${ROW}" rx="8"/>`,
      `<rect class="keyface" x="${(x + 2).toFixed(1)}" y="${top + 2}" width="${(w - 4).toFixed(1)}" height="${ROW - 4}" rx="6"/>`,
      g.center(key, "bold", x + w / 2, top + ROW / 2 + 7, KEY_SIZE, "ink"),
    );
    return w;
  };
  /// 打つ文字のまとまりを、表示を薄く書いた帯で x に描き、幅を返す
  const drawPiece = (p: Piece, x: number, top: number): number => {
    const text = p.shown.trim();
    const w = g.width(text, "regular", BAR_SIZE) + 24;
    const [tint, ink] =
      p.kind === "en" ? ["etint", "enmute"] : ["jtint", "jamute"];
    parts.push(
      `<rect class="${tint}" x="${x.toFixed(1)}" y="${top}" width="${w.toFixed(1)}" height="${ROW}" rx="6"/>`,
      g.draw(text, "regular", x + 12, top + ROW / 2 + 6, BAR_SIZE, ink),
    );
    return w;
  };

  const rows: [string, Lane[], string][] = [
    ["一般的な日本語入力", plainLanes, "bad"],
    ["tugime", tugimeLanes, "good"],
  ];
  const panelTop = (i: number) => 128 + i * (PANEL_H + PANEL_GAP);
  rows.forEach(([name, lanes, countClass], i) => {
    const top = panelTop(i);
    parts.push(
      `<rect class="panel" x="${LEFT}" y="${top}" width="${WIDTH - LEFT * 2}" height="${PANEL_H}" rx="14"/>`,
    );
    const hx = LEFT + PAD;
    parts.push(g.draw(name, "bold", hx, top + PAD + 18, 18, "ink"));
    const count = String(keyCount(lanes));
    const countBaseline = top + PAD + 18 + 56;
    parts.push(g.draw(count, "bold", hx, countBaseline, 52, countClass));
    parts.push(
      g.draw(
        "回",
        "regular",
        hx + g.width(count, "bold", 52) + 6,
        countBaseline,
        15,
        "sub",
      ),
    );
    parts.push(
      g.draw(
        "文字のほかに押すキー",
        "regular",
        hx,
        countBaseline + 24,
        13,
        "sub",
      ),
    );

    const linesH = lanes.length * ROW + (lanes.length - 1) * ROW_GAP;
    const linesTop = top + (PANEL_H - linesH) / 2;
    lanes.forEach((lane, j) => {
      const y = linesTop + j * (ROW + ROW_GAP);
      let x = hx + HEAD_W;
      for (const t of lane)
        x +=
          (typeof t === "string" ? drawKey(t, x, y) : drawPiece(t, x, y)) + GAP;
      const end = x - GAP;
      if (end > WIDTH - LEFT - PAD)
        throw new Error(
          `${name} の ${j + 1} 行目が枠からはみ出す（${end.toFixed(0)} > ${WIDTH - LEFT - PAD}）`,
        );
    });
  });

  const height = panelTop(rows.length) - PANEL_GAP + 36;
  await assertAlt("README.md", "intro.svg", [
    introExpected,
    `${keyCount(plainLanes)} 回`,
  ]);
  const label = `${introExpected} を打つとき、一般的な日本語入力では文字のほかに英数・かな・変換の Space・Enter を ${keyCount(plainLanes)} 回押す。tugime で文字のほかに押すのは最後の Enter だけ`;
  await writeImage(
    "intro.svg",
    svgDocument(SOURCE, WIDTH, height, label, g, parts.join(""), "auto", STYLE),
  );
}

// ── context.svg ───────────────────────────────────

{
  const WIDTH = 1100;
  const LEFT = 48;
  const PAD = 28;
  const ROW = 72;
  const TEXT_SIZE = 32;
  const INPUT_X = LEFT + PAD;
  const SHOWN_X = 336;
  /// 前の語と、それに合わせて決まった ひいて の表記の地と字
  const STYLE = `
  .ja { fill: #1d4ed8; } .goodtint { fill: #dcfce7; }
  @media (prefers-color-scheme: dark) { .ja { fill: #93c5fd; } .goodtint { fill: #14361f; } }`;

  const g = new Glyphs(fonts);
  const parts: string[] = [];
  parts.push(
    g.draw("同じ「ひいている」が、前の語で変わる", "bold", LEFT, 56, 22, "ink"),
    g.draw(
      "変換モデルが前の語を読んで、続きの漢字を決める",
      "regular",
      LEFT,
      86,
      15,
      "sub",
    ),
  );

  const panelTop = 116;
  const panelHeight = contextRows.length * ROW + 16;
  parts.push(
    `<rect class="panel" x="${LEFT}" y="${panelTop}" width="${WIDTH - LEFT * 2}" height="${panelHeight}" rx="14"/>`,
  );
  /// text を x から地を敷いて描き、幅を返す
  const marked = (
    text: string,
    x: number,
    top: number,
    baseline: number,
    tint: string,
    ink: string,
  ): number => {
    const w = g.width(text, "bold", TEXT_SIZE);
    parts.push(
      `<rect class="${tint}" x="${(x - 4).toFixed(1)}" y="${top + 14}" width="${(w + 8).toFixed(1)}" height="${ROW - 28}" rx="6"/>`,
      g.draw(text, "bold", x, baseline, TEXT_SIZE, ink),
    );
    return w;
  };
  contextRows.forEach((r, i) => {
    const top = panelTop + 8 + i * ROW;
    if (i > 0)
      parts.push(
        `<rect class="chip" x="${LEFT + PAD}" y="${top}" width="${WIDTH - (LEFT + PAD) * 2}" height="1"/>`,
      );
    const keyBaseline = top + ROW / 2 + 6;
    const rest = r.input.slice(r.typedWord.length);
    parts.push(
      g.draw(r.typedWord, "bold", INPUT_X, keyBaseline, 18, "ink"),
      g.draw(
        rest,
        "regular",
        INPUT_X + g.width(r.typedWord, "bold", 18),
        keyBaseline,
        18,
        "sub",
      ),
    );
    if (INPUT_X + g.width(r.input, "bold", 18) > SHOWN_X - 24)
      throw new Error(`${r.input} の打鍵が表示の列に近すぎる`);
    const baseline = top + ROW / 2 + 11;
    let x = SHOWN_X;
    x += marked(r.word, x, top, baseline, "jtint", "ja") + 6;
    parts.push(g.draw(r.particle, "bold", x, baseline, TEXT_SIZE, "ink"));
    x += g.width(r.particle, "bold", TEXT_SIZE) + 6;
    x += marked(r.verb, x, top, baseline, "goodtint", "good") + 4;
    parts.push(g.draw(r.after, "bold", x, baseline, TEXT_SIZE, "ink"));
    if (x + g.width(r.after, "bold", TEXT_SIZE) > WIDTH - LEFT - PAD)
      throw new Error(`${r.input} の表示が枠からはみ出す`);
  });

  const height = panelTop + panelHeight + 36;
  const shown = contextRows.map((r) => r.word + r.particle + r.verb + r.after);
  const label = `同じ読み ひいている の前の語だけを変えて打つと、tugime は ${shown.join(" ")} と前の語に合わせて変換する`;
  await assertAlt("README.md", "context.svg", shown);
  await writeImage(
    "context.svg",
    svgDocument(SOURCE, WIDTH, height, label, g, parts.join(""), "auto", STYLE),
  );
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
    parts.push(
      g.draw(
        caption,
        "regular",
        AXIS_LEFT + g.width(title, "bold", 14) + 10,
        y,
        12,
        "sub",
      ),
    );
  };
  const separator = () => {
    y += 22;
    parts.push(
      `<rect class="chip" x="${LEFT}" y="${y}" width="${WIDTH - LEFT * 2}" height="1"/>`,
    );
    y += 40;
  };
  const segmentClass = (kind: Kind) => (kind === "E" ? "en" : "ink");

  y = 44;
  parts.push(g.draw("打鍵列から変換するまで", "bold", LEFT, y, 20, "ink"));
  y += 26;
  parts.push(
    g.draw(
      "打鍵のたびに、打鍵列の範囲を日本語や英語として読む候補を挙げて点を付け、点の合計が最も高い読み方の並びを採る。",
      "regular",
      LEFT,
      y,
      13,
      "sub",
    ),
  );

  // 打ちたい文を、区間ごとにその打鍵の範囲の上に置く
  y += 46;
  parts.push(g.draw("打ちたい文", "regular", LEFT, y, 13, "sub"));
  for (const { segment: s, text } of splitShown(
    finalSegments,
    finalStep.shown,
  )) {
    parts.push(
      g.center(
        text,
        "bold",
        (x(s.s) + x(s.e)) / 2,
        y + 2,
        22,
        segmentClass(s.kind),
      ),
    );
  }
  y += 40;
  parts.push(g.draw("打鍵列", "regular", LEFT, y, 13, "sub"));
  [...input].forEach((c, i) =>
    parts.push(g.center(c, "bold", x(i) + CELL / 2, y, 20, "ink")),
  );

  // 比べた読み方: 区間の候補を、始まりの早い順、長い順に、重ならない段へ詰める
  const unique = new Map<string, Span>();
  for (const span of lattice)
    unique.set(`${span.s}-${span.e}-${span.kind}`, span);
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
  head(
    "比べた読み方",
    `線 1 本が真上の打鍵を 1 区間として読む候補（範囲と読み方の組で ${placed.length} 通り）。濃い線は最後に採った区間`,
  );
  y += 16;
  const latticeTop = y;
  for (const p of placed) {
    const on = chosenKeys.has(`${p.s}-${p.e}-${p.kind}`);
    const top = latticeTop + p.lane * (LINE + LINE_GAP) - (on ? 1 : 0);
    parts.push(
      `<rect class="${segmentClass(p.kind)}" opacity="${on ? 1 : 0.35}" x="${x(p.s) + 1}" y="${top}" width="${(p.e - p.s) * CELL - 2}" height="${on ? LINE + 2 : LINE}"/>`,
    );
  }
  y = latticeTop + laneEnds.length * (LINE + LINE_GAP) + 26;
  let lx = AXIS_LEFT;
  for (const [cls, text] of [
    ["ink", "日本語として読む候補（かな漢字変換の評価値が点）"],
    ["en", "英語として読む候補（英語の語としてのありそうさが点）"],
  ] as const) {
    parts.push(
      `<rect class="${cls}" x="${lx}" y="${y - 5}" width="22" height="3"/>`,
    );
    parts.push(g.draw(text, "regular", lx + 30, y, 12, "sub"));
    lx += 30 + g.width(text, "regular", 12) + 28;
  }
  separator();

  // 採った読み方: 打鍵が進むごとに採った区間の並びと、その表示
  head(
    "採った読み方",
    "打鍵が進むごとに採った区間の並びと、その表示。左は新しく打ったキー",
  );
  y += 14;
  const clips: string[] = [];
  steps.forEach((s, row) => {
    const top = y + row * (BAR + ROW_GAP);
    const previousEnd = row === 0 ? 0 : stepEnds[row - 1];
    parts.push(
      g.right(
        `${row === 0 ? "" : "+"}${s.prefix.slice(previousEnd)}`,
        "bold",
        AXIS_LEFT - 14,
        top + BAR / 2 + 5,
        13,
        "sub",
      ),
    );
    splitShown(s.segments, s.shown).forEach(({ segment: seg, text }, i) => {
      const bx = x(seg.s) + 1;
      const bw = (seg.e - seg.s) * CELL - 2;
      const id = `c${row}-${i}`;
      clips.push(
        `<clipPath id="${id}"><rect x="${bx}" y="${top}" width="${bw}" height="${BAR}"/></clipPath>`,
      );
      parts.push(
        `<rect class="${seg.kind === "E" ? "etint" : "jtint"}" x="${bx}" y="${top}" width="${bw}" height="${BAR}" rx="3"/>`,
      );
      parts.push(
        `<g clip-path="url(#${id})">${g.center(text, "bold", bx + bw / 2, top + BAR / 2 + 5.5, 15, segmentClass(seg.kind))}</g>`,
      );
    });
  });
  y += steps.length * (BAR + ROW_GAP) - ROW_GAP;
  separator();

  // 英語として読む理由
  head(
    `${englishWord} を英語として読む理由`,
    "それぞれの読み方で、最も高い並びの点の合計（高いほうを採る）。表記は点を付けるときの変換",
  );
  const japaneseX = AXIS_LEFT + 130;
  const englishX = AXIS_LEFT + 470;
  y += 32;
  parts.push(
    g.draw("全部を日本語として読む", "regular", japaneseX, y, 12, "sub"),
  );
  parts.push(
    g.draw(
      `${englishWord} を英語として読む`,
      "regular",
      englishX,
      y,
      12,
      "sub",
    ),
  );
  y += 32;
  parts.push(g.draw("最後まで", "regular", AXIS_LEFT, y, 13, "sub"));
  for (const [path, other, column] of [
    [japanese, english, japaneseX],
    [english, japanese, englishX],
  ] as const) {
    const win = path.total > other.total;
    const score = path.total.toFixed(1);
    parts.push(g.draw(score, "regular", column, y, 14, win ? "good" : "sub"));
    parts.push(
      g.draw(
        path.spans.map((s) => s.output).join(" + "),
        "regular",
        column + g.width(score, "regular", 14) + 12,
        y,
        14,
        win ? "good" : "ink",
      ),
    );
  }
  const height = y + 36;
  const label = `${expected} を打ち進めるごとの表示と、その裏で比べた読み方の候補。打鍵列の範囲を日本語や英語として読む候補を挙げ、点の合計が最も高い並びを採る。${englishWord} は、${input[japaneseWordAt - 1]} を打った時点では日本語の ${japaneseWord} に読まれ、${input.slice(japaneseWordAt - 1, japaneseWordAt + 1)} まで打つと英語に戻る`;
  await assertAlt("docs/how-it-works.md", "conversion.svg", [label]);
  await writeImage(
    "conversion.svg",
    svgDocument(
      SOURCE,
      WIDTH,
      height,
      label,
      g,
      `<defs>${clips.join("")}</defs>${parts.join("")}`,
    ),
  );
}
