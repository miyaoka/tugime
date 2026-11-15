// README の安全性の図 docs/images/safety.svg を作る。打った文字が入力欄と tugime の間だけを行き来し、外へ出ないことを描く。
// 使い方: bun install --cwd scripts && bun scripts/make-safety.ts
import {
  Glyphs,
  assertAlt,
  kindOf,
  loadFonts,
  svgDocument,
  writeImage,
} from "./lib/svg";

const SOURCE = "scripts/make-safety.ts";

const TITLE = "打った文字は、入力欄にしか届かない";
const SUBTITLE =
  "tugime は打った文字を変換して返すだけで、外へ送らず、残さない";
const SHOWN = "zipを解凍した。";
/// 外へ出ない先。名前と、出ない理由（2 行）
const BLOCKED: [string, [string, string]][] = [
  ["インターネット", ["通信しない。Sandbox が", "通信を許していない"]],
  ["保存・学習", ["打った内容を保存せず、", "打ち方を学習しない"]],
];
const PASSWORD = "パスワード欄";
const PASSWORD_NOTE =
  "入力ソースを英字のものに限るアプリ（Chrome など）では、tugime は選ばれず、変換しない";

const WIDTH = 1100;
const HEIGHT = 440;
const LEFT = 48;

/// 入力欄、tugime の枠、外へ出ない先の線と枠の色。共有の配色に無いものだけを足す
const STYLE = `
  .field { fill: #ffffff; stroke: #d0d7de; } .dash { stroke: #9ca3af; stroke-width: 2; stroke-dasharray: 6 5; }
  .tbox { fill: #eff6ff; stroke: #2563eb; stroke-width: 2; } .blue { fill: #1d4ed8; }
  .xline { stroke: #dc2626; stroke-width: 3; stroke-dasharray: 6 5; } .xmark { stroke: #dc2626; stroke-width: 3; stroke-linecap: round; }
  .outbox { fill: none; stroke: #d1d5db; stroke-dasharray: 4 4; }
  @media (prefers-color-scheme: dark) {
    .field { fill: #0d1117; stroke: #30363d; } .dash { stroke: #6b7280; }
    .tbox { fill: #0f1d33; stroke: #3b82f6; } .blue { fill: #93c5fd; }
    .xline { stroke: #f87171; } .xmark { stroke: #f87171; } .outbox { stroke: #4b5563; }
  }`;

const g = new Glyphs(await loadFonts());
const label = `${TITLE}。入力欄で打った文字は tugime が変換して入力欄に返す。tugime は macOS の Sandbox の中で動く。届かない先は ${BLOCKED.map(([name, why]) => `${name}（${why.join("")}）`).join("、")}。${PASSWORD}: ${PASSWORD_NOTE}`;
await assertAlt("README.md", "safety.svg", [
  TITLE,
  ...BLOCKED.map(([name]) => name),
  PASSWORD,
]);

const parts: string[] = [];
parts.push(
  g.draw(TITLE, "bold", LEFT, 56, 22, "ink"),
  g.draw(SUBTITLE, "regular", LEFT, 86, 15, "sub"),
);

/// 線の矢印。from から to へ、y の高さで引く
const arrow = (from: number, to: number, y: number) => {
  const dir = Math.sign(to - from);
  return `<rect class="ink" x="${Math.min(from, to - dir * 12)}" y="${y - 1.5}" width="${Math.abs(to - from) - 12}" height="3"/><polygon class="ink" points="${to},${y} ${to - dir * 14},${y - 7} ${to - dir * 14},${y + 7}"/>`;
};

// 入力欄
const field = { x: LEFT, y: 140, w: 300, h: 110 };
parts.push(
  `<rect class="field" x="${field.x}" y="${field.y}" width="${field.w}" height="${field.h}" rx="12"/>`,
  `<path class="panel" d="M${field.x + 1} ${field.y + 30} V${field.y + 12} a11 11 0 0 1 11 -11 H${field.x + field.w - 12} a11 11 0 0 1 11 11 V${field.y + 30} Z"/>`,
  ...[0, 1, 2].map(
    (k) =>
      `<circle class="sub" cx="${field.x + 18 + k * 18}" cy="${field.y + 16}" r="5"/>`,
  ),
  g.draw(
    "どのアプリの入力欄でも",
    "regular",
    field.x + 74,
    field.y + 21,
    13,
    "sub",
  ),
  g.draw(SHOWN, "bold", field.x + 26, field.y + 76, 26, kindOf),
  `<line class="dash" x1="${field.x + 14}" y1="${field.y + 88}" x2="${field.x + field.w - 14}" y2="${field.y + 88}"/>`,
);

// tugime の枠と、入力欄との往復
const box = { x: 470, y: 120, w: 260, h: 170 };
const between = field.x + field.w + 2;
parts.push(
  arrow(between, box.x - 4, 175),
  arrow(box.x - 4, between, 235),
  g.draw("打った文字", "regular", 372, 164, 14, "sub"),
  g.draw("変換した表示", "regular", 372, 258, 14, "sub"),
  `<rect class="tbox" x="${box.x}" y="${box.y}" width="${box.w}" height="${box.h}" rx="14"/>`,
  g.draw("tugime", "bold", box.x + 20, box.y + 38, 22, "ink"),
  g.draw(
    "macOS の Sandbox の中で動く",
    "regular",
    box.x + 20,
    box.y + 62,
    13,
    "blue",
  ),
  g.draw("辞書と変換モデルは", "regular", box.x + 20, box.y + 104, 14, "sub"),
  g.draw("手元にある", "regular", box.x + 20, box.y + 128, 14, "sub"),
);

// 外へ出ない先
const out = { x: 820, w: WIDTH - LEFT - 820, h: 96 };
BLOCKED.forEach(([name, why], i) => {
  const top = 112 + i * 110;
  const lineY = top + 48;
  parts.push(
    `<line class="xline" x1="${box.x + box.w + 2}" y1="${lineY}" x2="${out.x - 4}" y2="${lineY}"/>`,
    `<rect class="outbox" x="${out.x}" y="${top}" width="${out.w}" height="${out.h}" rx="12"/>`,
    `<path class="xmark" d="M${out.x + 16} ${top + 18} l12 12 M${out.x + 28} ${top + 18} l-12 12"/>`,
    g.draw(name, "bold", out.x + 36, top + 31, 17, "sub"),
    ...why.map((line, k) =>
      g.draw(line, "regular", out.x + 16, top + 56 + k * 20, 13, "sub"),
    ),
  );
  const widest = Math.max(
    out.x + 36 + g.width(name, "bold", 17),
    ...why.map((line) => out.x + 16 + g.width(line, "regular", 13)),
  );
  if (widest > out.x + out.w - 12)
    throw new Error(`${name} の枠の文字がはみ出す`);
});

// パスワード欄
const pw = { y: 350, h: 68 };
const pwField = { x: LEFT + 18, y: pw.y + 16, w: 100, h: 36 };
const noteX = pwField.x + pwField.w + 20;
const noteRest = noteX + g.width(PASSWORD, "bold", 15) + 14;
parts.push(
  `<rect class="panel" x="${LEFT}" y="${pw.y}" width="${WIDTH - LEFT * 2}" height="${pw.h}" rx="12"/>`,
  `<rect class="field" x="${pwField.x}" y="${pwField.y}" width="${pwField.w}" height="${pwField.h}" rx="8"/>`,
  ...[0, 1, 2, 3, 4, 5].map(
    (k) =>
      `<circle class="ink" cx="${pwField.x + 20 + k * 12}" cy="${pwField.y + pwField.h / 2}" r="3"/>`,
  ),
  g.draw(PASSWORD, "bold", noteX, pw.y + 39, 15, "ink"),
  g.draw(PASSWORD_NOTE, "regular", noteRest, pw.y + 39, 15, "ink"),
);
if (noteRest + g.width(PASSWORD_NOTE, "regular", 15) > WIDTH - LEFT - 18)
  throw new Error("パスワード欄の説明がはみ出す");

await writeImage(
  "safety.svg",
  svgDocument(SOURCE, WIDTH, HEIGHT, label, g, parts.join(""), "auto", STYLE),
);
