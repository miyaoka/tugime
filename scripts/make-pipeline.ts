// README の変換の仕組みの図 docs/images/pipeline.svg を tugime-cli の出力から作る。
// 利用者が打ってから入力欄に出るまでの間に tugime が自動で行う工程を並べ、各工程で打鍵列がどの形になるかと、働く部品を載せる
// 使い方: bun install --cwd scripts && bun scripts/make-pipeline.ts
import assert from "node:assert";
import {
  Glyphs,
  assertAlt,
  cli,
  kindOf,
  prepare,
  readExplains,
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

// ── tugime-cli から値を読む ─────────────────────────

/// 打鍵列の日本語の文節の読みをつないだもの（--clauses）
async function readReading(input: string): Promise<string> {
  let reading = "";
  let inside = false;
  for (const line of (await run([cli, "--clauses", input])).split("\n")) {
    if (line === `== ${input}`) {
      inside = true;
      continue;
    }
    // 種類 読み<TAB>候補。変換エンジンのログも標準出力に混ざるので、種類と空白で始まりタブを含む行だけを文節として読む
    const clause = line.match(/^([JEP]) ([^\t]+)\t/);
    if (!clause) continue;
    if (!inside) throw new Error(`== の行より前に文節がある: ${line}`);
    if (clause[1] === "J") reading += clause[2];
  }
  if (!reading) throw new Error(`--clauses に日本語の文節が無い: ${input}`);
  return reading;
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
  const kinds = segments.map((s) => s.kind).join("");
  if (kinds !== "EJP")
    throw new Error(`区切りの種類 ${kinds} が 英語・日本語・句読点 の順でない`);
  const [shown] = readLive(
    await run([cli, "--method", `direct:${model}`, "--live", INPUT]),
    [INPUT],
  );
  if (shown?.shown !== SHOWN)
    throw new Error(`表示 ${shown?.shown} が ${SHOWN} と違う`);
  const [en, ja, punct] = SCORED;
  if (!SHOWN.startsWith(en) || !SHOWN.endsWith(punct))
    throw new Error(`表示 ${SHOWN} が ${en} で始まり ${punct} で終わらない`);
  return {
    en,
    reading: await readReading(INPUT),
    scored: ja,
    converted: SHOWN.slice(en.length, SHOWN.length - punct.length),
    punct,
  };
}

// ── 図 ────────────────────────────────────────
// 左に利用者が見るもの（打鍵から入力欄の表示まで）を縦に置き、右に tugime がその間に自動で行う工程を縦に並べる

type ChipKind = "key" | "en" | "ja" | "p" | "good";
type Row = {
  title: string;
  chips: [string, ChipKind][];
  /// 帯の下に添える、この工程の出力についての注記
  note?: string;
  parts: [string, string][];
};

const WIDTH = 1100;
const LEFT = 48;
/// 左の矢印の x
const ARROW_X = 150;
const PANEL_X = 430;
const PANEL_PAD = 22;
/// 右の枠の中で、工程名の列の幅
const TITLE_W = 186;
const CHIP_H = 40;
const CHIP_SIZE = 20;

/// 素材の帯の地と字、工程の番号、入力欄の色。共有の配色に無いものだけを足す
const STYLE = `
  .ja { fill: #1d4ed8; } .ptint { fill: #dcfce7; } .num { fill: #2563eb; } .num4 { fill: #7c3aed; } .onnum { fill: #ffffff; }
  .goodline { fill: none; stroke: #15803d; stroke-width: 2; } .field { fill: #ffffff; stroke: #d0d7de; }
  .dash { stroke: #9ca3af; stroke-width: 2; stroke-dasharray: 6 5; }
  @media (prefers-color-scheme: dark) {
    .ja { fill: #93c5fd; } .ptint { fill: #14361f; } .num { fill: #3b82f6; } .num4 { fill: #8b5cf6; }
    .goodline { stroke: #4ade80; } .field { fill: #0d1117; stroke: #30363d; } .dash { stroke: #6b7280; }
  }`;

const CHIP_CLASS: Record<ChipKind, [string, string]> = {
  key: ["chip", "ink"],
  en: ["etint", "en"],
  ja: ["jtint", "ja"],
  p: ["ptint", "good"],
  good: ["jtint", "good"],
};

async function main() {
  const { model, fonts } = await prepare();
  const v = await step("tugime-cli の結果の読み取り", () => readValues(model));
  const g = new Glyphs(fonts);
  const parts: string[] = [];

  const rows: Row[] = [
    {
      title: "受け取る",
      chips: [[INPUT, "key"]],
      parts: [["InputMethodKit", "macOS の入力の仕組み"]],
    },
    {
      title: "読み分ける",
      chips: [
        [v.en, "en"],
        [v.reading, "ja"],
        // 句読点の形は、直前の区間の言語が決まる工程 3 で決まる
        [INPUT.slice(-1), "key"],
      ],
      parts: [["ローマ字の綴りの表", `${v.en} は読めないので英語にする`]],
    },
    {
      title: "区切りを決める",
      chips: [
        [v.en, "en"],
        [v.scored, "ja"],
        [v.punct, "p"],
      ],
      note: "区切りが決まる。漢字はまだ仮",
      parts: [
        ["システム辞書", "Mozc の辞書と品詞の連接"],
        ["wordfreq・Webster's", "英語の語の頻度と語表"],
      ],
    },
    {
      title: "変換を仕上げる",
      chips: [
        [v.en, "en"],
        [v.converted, "good"],
        [v.punct, "p"],
      ],
      parts: [
        ["genmai-310M", "変換モデル"],
        ["llama.cpp", "Mac の GPU で動かす"],
      ],
    },
  ];

  parts.push(g.draw("打鍵が文になるまで", "bold", LEFT, 58, 26, "ink"));
  parts.push(g.draw(`${INPUT} と打ったとき`, "regular", LEFT, 90, 15, "sub"));

  // 右: tugime が自動で行う工程
  const panelTop = 118;
  const panelW = WIDTH - LEFT - PANEL_X;
  const body: string[] = [];
  body.push(
    g.draw(
      "tugime が自動で行うこと",
      "bold",
      PANEL_X + PANEL_PAD,
      panelTop + 40,
      18,
      "ink",
    ),
  );
  let rowTop = panelTop + 56;
  rows.forEach((r, i) => {
    if (i > 0)
      body.push(
        `<rect class="chip" x="${PANEL_X + PANEL_PAD}" y="${rowTop}" width="${panelW - PANEL_PAD * 2}" height="1"/>`,
      );
    const chipTop = rowTop + 14;
    const cy = chipTop + CHIP_H / 2;
    const cx = PANEL_X + PANEL_PAD + 14;
    body.push(
      `<circle class="${i === rows.length - 1 ? "num4" : "num"}" cx="${cx}" cy="${cy}" r="14"/>`,
      g.center(String(i + 1), "bold", cx, cy + 6, 16, "onnum"),
      g.draw(r.title, "bold", cx + 22, cy + 7, 18, "ink"),
    );
    const chipLeft = PANEL_X + PANEL_PAD + TITLE_W;
    if (cx + 22 + g.width(r.title, "bold", 18) > chipLeft - 12)
      throw new Error(`工程名 ${r.title} が素材の帯に近すぎる`);
    let chipX = chipLeft;
    for (const [t, kind] of r.chips) {
      const [tint, ink] = CHIP_CLASS[kind];
      const w = g.width(t, "bold", CHIP_SIZE) + 18;
      body.push(
        `<rect class="${tint}" x="${chipX.toFixed(1)}" y="${chipTop}" width="${w.toFixed(1)}" height="${CHIP_H}" rx="6"/>`,
      );
      if (kind === "good")
        body.push(
          `<rect class="goodline" x="${(chipX + 1).toFixed(1)}" y="${chipTop + 1}" width="${(w - 2).toFixed(1)}" height="${CHIP_H - 2}" rx="6"/>`,
        );
      body.push(g.draw(t, "bold", chipX + 9, cy + 7, CHIP_SIZE, ink));
      chipX += w + 4;
    }
    if (chipX - 4 > PANEL_X + panelW - PANEL_PAD)
      throw new Error(`${r.title} の素材が枠からはみ出す`);
    let partY = chipTop + CHIP_H;
    if (r.note) {
      partY += 20;
      body.push(g.draw(r.note, "regular", chipLeft, partY, 13, "sub"));
    }
    for (const [name, role] of r.parts) {
      partY += 20;
      body.push(g.draw(name, "bold", chipLeft, partY, 14, "ink"));
      body.push(
        g.draw(
          role,
          "regular",
          chipLeft + g.width(name, "bold", 14) + 6,
          partY,
          12,
          "sub",
        ),
      );
    }
    rowTop = partY + 16;
  });
  const panelBottom = rowTop + 6;
  parts.push(
    `<rect class="panel" x="${PANEL_X}" y="${panelTop}" width="${panelW}" height="${panelBottom - panelTop}" rx="14"/>`,
    ...body,
  );

  // 左: 打つ → 入力欄に出る
  parts.push(g.draw("打つ", "bold", LEFT, 134, 15, "sub"));
  const keysTop = 146;
  const keysH = 56;
  const keysW = g.width(INPUT, "bold", 24) + 28;
  if (LEFT + keysW > PANEL_X - 24) throw new Error("打鍵の箱が右の枠に重なる");
  parts.push(
    `<rect class="chip" x="${LEFT}" y="${keysTop}" width="${keysW.toFixed(1)}" height="${keysH}" rx="8"/>`,
    g.draw(INPUT, "bold", LEFT + 14, keysTop + 37, 24, "ink"),
  );
  const arrowTop = keysTop + keysH + 6;
  const arrowEnd = panelBottom;
  parts.push(
    `<rect class="sub" x="${ARROW_X - 1.5}" y="${arrowTop}" width="3" height="${arrowEnd - arrowTop - 12}"/>`,
    `<polygon class="sub" points="${ARROW_X - 8},${arrowEnd - 14} ${ARROW_X + 8},${arrowEnd - 14} ${ARROW_X},${arrowEnd}"/>`,
  );
  const note = ["1 キーごとに", "右の処理を", "tugime が", "自動で行う"];
  const noteTop = (arrowTop + arrowEnd) / 2 - (note.length * 24) / 2;
  note.forEach((line, i) =>
    parts.push(
      g.draw(line, "regular", ARROW_X + 16, noteTop + 18 + i * 24, 15, "sub"),
    ),
  );

  const labelY = arrowEnd + 30;
  parts.push(g.draw("入力欄に出る", "bold", LEFT, labelY, 15, "sub"));
  const fieldTop = labelY + 12;
  const fieldW = 330;
  const textY = fieldTop + 30 + 48;
  const fieldH = textY + 12 + 30 - fieldTop;
  parts.push(
    `<rect class="field" x="${LEFT}" y="${fieldTop}" width="${fieldW}" height="${fieldH}" rx="12"/>`,
    `<path class="panel" d="M${LEFT + 1} ${fieldTop + 30} V${fieldTop + 12} a11 11 0 0 1 11 -11 H${LEFT + fieldW - 12} a11 11 0 0 1 11 11 V${fieldTop + 30} Z"/>`,
    ...[0, 1, 2].map(
      (k) =>
        `<circle class="sub" cx="${LEFT + 18 + k * 18}" cy="${fieldTop + 16}" r="5"/>`,
    ),
    g.draw("アプリの入力欄", "regular", LEFT + 74, fieldTop + 21, 13, "sub"),
    g.draw(SHOWN, "bold", LEFT + 26, textY, 30, kindOf),
    `<line class="dash" x1="${LEFT + 14}" y1="${textY + 12}" x2="${LEFT + fieldW - 14}" y2="${textY + 12}"/>`,
    g.draw("未確定。Enter で確定", "regular", LEFT + 14, textY + 32, 12, "sub"),
  );
  if (LEFT + 26 + g.width(SHOWN, "bold", 30) > LEFT + fieldW - 14)
    throw new Error("入力欄の文がはみ出す");

  const height = fieldTop + fieldH + 36;
  const label = `${INPUT} と打つと、入力欄に ${SHOWN} と出る。その間に tugime は 1 受け取る（InputMethodKit）、2 読み分ける（ローマ字の綴りの表。${v.en} は読めないので英語）、3 区切りを決める（システム辞書、wordfreq・Webster's。${v.en}｜${v.scored}｜${v.punct}）、4 変換を仕上げる（genmai-310M、llama.cpp。${SHOWN}）を自動で行う`;
  await assertAlt("README.md", "pipeline.svg", [
    INPUT,
    `${v.en}｜${v.scored}｜${v.punct}`,
    SHOWN,
    "自動で行う",
  ]);
  await writeImage(
    "pipeline.svg",
    svgDocument(SOURCE, WIDTH, height, label, g, parts.join(""), "auto", STYLE),
  );
}

await main();
