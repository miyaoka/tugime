// README の安全性の図 docs/images/safety.svg を作る。打った文字が入力欄と tugime の間だけを行き来し、外へ出ないことを描く。
// 使い方: bun install --cwd scripts && bun scripts/make-safety.ts
import {
  Glyphs,
  assertAlt,
  inputField,
  loadFonts,
  svgDocument,
  writeImage,
} from "./lib/svg";

const SOURCE = "scripts/make-safety.ts";

const TITLE = "打った文字は外へ送らず残さない";
const SHOWN = "zipを解凍した。";
/// 届かない先。名前と、届かない理由（2 行）
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

/// tugime の枠と、届かない先の線と枠の色。共有の配色に無いものだけを足す
const STYLE = `
  .tbox { fill: #eff6ff; stroke: #2563eb; stroke-width: 2; } .blue { fill: #1d4ed8; }
  .xline { stroke: #dc2626; stroke-width: 3; stroke-dasharray: 6 5; } .xmark { stroke: #dc2626; stroke-width: 3; stroke-linecap: round; }
  .outbox { fill: none; stroke: #d1d5db; stroke-dasharray: 4 4; }
  @media (prefers-color-scheme: dark) {
    .tbox { fill: #0f1d33; stroke: #3b82f6; } .blue { fill: #93c5fd; }
    .xline { stroke: #f87171; } .xmark { stroke: #f87171; } .outbox { stroke: #4b5563; }
  }`;

const g = new Glyphs(await loadFonts());
const label = `${TITLE}。入力欄で打った文字は tugime が変換して入力欄に返す。tugime は macOS の Sandbox の中で動く。届かない先は ${BLOCKED.map(([name, why]) => `${name}（${why.join("")}）`).join("、")}。${PASSWORD}: ${PASSWORD_NOTE}`;
await assertAlt("README.md", "safety.svg", [label]);

const parts: string[] = [];
parts.push(g.drawWithin(TITLE, "bold", LEFT, 56, 22, "ink", WIDTH - LEFT));

/// 線の矢印。from から to へ、y の高さで引く
const arrow = (from: number, to: number, y: number) => {
  const dir = Math.sign(to - from);
  return `<rect class="ink" x="${Math.min(from, to - dir * 12)}" y="${y - 1.5}" width="${Math.abs(to - from) - 12}" height="3"/><polygon class="ink" points="${to},${y} ${to - dir * 14},${y - 7} ${to - dir * 14},${y + 7}"/>`;
};

// 入力欄
const field = { x: LEFT, y: 140, w: 300 };
parts.push(
  ...inputField(
    g,
    field.x,
    field.y,
    field.w,
    "どのアプリの入力欄でも",
    SHOWN,
    26,
  ).parts,
);

// tugime の枠と、入力欄との往復
const box = { x: 470, y: 120, w: 260, h: 170 };
const between = field.x + field.w + 2;
parts.push(
  arrow(between, box.x - 4, 175),
  arrow(box.x - 4, between, 235),
  g.drawWithin("打った文字", "regular", 372, 164, 14, "sub", box.x - 4),
  g.drawWithin("変換した表示", "regular", 372, 258, 14, "sub", box.x - 4),
  `<rect class="tbox" x="${box.x}" y="${box.y}" width="${box.w}" height="${box.h}" rx="14"/>`,
  g.draw("tugime", "bold", box.x + 20, box.y + 38, 22, "ink"),
  g.drawWithin(
    "macOS の Sandbox の中で動く",
    "regular",
    box.x + 20,
    box.y + 62,
    13,
    "blue",
    box.x + box.w - 12,
  ),
  g.drawWithin(
    "辞書と変換モデルは",
    "regular",
    box.x + 20,
    box.y + 104,
    14,
    "sub",
    box.x + box.w - 12,
  ),
  g.draw("手元にある", "regular", box.x + 20, box.y + 128, 14, "sub"),
);

// 届かない先
const out = { x: 820, w: WIDTH - LEFT - 820, h: 96 };
BLOCKED.forEach(([name, why], i) => {
  const top = 112 + i * 110;
  const lineY = top + 48;
  parts.push(
    `<line class="xline" x1="${box.x + box.w + 2}" y1="${lineY}" x2="${out.x - 4}" y2="${lineY}"/>`,
    `<rect class="outbox" x="${out.x}" y="${top}" width="${out.w}" height="${out.h}" rx="12"/>`,
    `<path class="xmark" d="M${out.x + 16} ${top + 18} l12 12 M${out.x + 28} ${top + 18} l-12 12"/>`,
    g.drawWithin(
      name,
      "bold",
      out.x + 36,
      top + 31,
      17,
      "sub",
      out.x + out.w - 12,
    ),
    ...why.map((line, k) =>
      g.drawWithin(
        line,
        "regular",
        out.x + 16,
        top + 56 + k * 20,
        13,
        "sub",
        out.x + out.w - 12,
      ),
    ),
  );
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
  g.drawWithin(
    PASSWORD_NOTE,
    "regular",
    noteRest,
    pw.y + 39,
    15,
    "ink",
    WIDTH - LEFT - 18,
  ),
);

await writeImage(
  "safety.svg",
  svgDocument(SOURCE, WIDTH, HEIGHT, label, g, parts.join(""), "auto", STYLE),
);
