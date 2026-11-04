// README の冒頭の紹介画像 docs/images/hero.svg を作る。ロゴ（下線を引いた「つ」）、ルビを振った名前、コピーを並べる。
// 名前は、点線の下線を引いた tugime の右に、実線の下線を引いた 継ぎ目 を置き、打った名前が変換されて 継ぎ目 になる様子にたとえる。
// 使い方: bun install --cwd scripts && bun scripts/make-hero.ts
import {
  Glyphs,
  assertAlt,
  loadFonts,
  svgDocument,
  writeImage,
} from "./lib/svg";

const SOURCE = "scripts/make-hero.ts";

/// 名前の音節と、その上に振るルビ
const SYLLABLES = [
  ["tu", "つ"],
  ["gi", "ぎ"],
  ["me", "め"],
] as const;
const NAME = SYLLABLES.map(([roman]) => roman).join("");
const KANJI = "継ぎ目";
const LOGO = "つ";
const COPY = "英語まじりの日本語を、継ぎ目なく。";
const SUBCOPY = "日英を自動で区分けし、文脈を汲んで変換する日本語入力";

const WIDTH = 900;
const HEIGHT = 300;
const TILE = 180;
const TILE_X = 40;
const TILE_Y = (HEIGHT - TILE) / 2;
const TILE_RADIUS = 40;
const LOGO_SIZE = 112;
/// ロゴの下線。gap は字の形の下端から下線までの間
const LOGO_UNDERLINE = { width: 92, height: 9, gap: 22 };
const TEXT_X = TILE_X + TILE + 44;
const NAME_SIZE = 76;
const NAME_BASELINE = 140;
const RUBY_SIZE = 19;
/// 名前の字の形の上端からルビのベースラインまでの間
const RUBY_GAP = 8;
const KANJI_SIZE = 42;
const KANJI_GAP = 26;
/// 名前の字の形の下端（g の下に出る部分）から下線までの間
const UNDERLINE_GAP = 8;
const UNDERLINE_HEIGHT = 5;
const DOT = { radius: 1.6, pitch: 9 };
const COPY_SIZE = 27;
const COPY_BASELINE = 214;
const SUBCOPY_SIZE = 18;
const SUBCOPY_BASELINE = 250;

/// ロゴの四角の枠。塗りは共有の .panel を使う
const STYLE = `
  .tile { stroke: #d0d7de; stroke-width: 1.5; }
  @media (prefers-color-scheme: dark) { .tile { stroke: #30363d; } }`;

const g = new Glyphs(await loadFonts());
await assertAlt("README.md", "hero.svg", [NAME, KANJI, COPY, SUBCOPY]);

const parts: string[] = [];

// ロゴ: 角丸の四角の中央に、「つ」の字の形と下線をまとめて置く
const tileCx = TILE_X + TILE / 2;
parts.push(
  `<rect class="panel tile" x="${TILE_X}" y="${TILE_Y}" width="${TILE}" height="${TILE}" rx="${TILE_RADIUS}"/>`,
);
const logoInk = g.ink(LOGO, "bold", LOGO_SIZE);
const logoHeight =
  logoInk.top + logoInk.bottom + LOGO_UNDERLINE.gap + LOGO_UNDERLINE.height;
const logoBaseline = TILE_Y + (TILE - logoHeight) / 2 + logoInk.top;
parts.push(g.center(LOGO, "bold", tileCx, logoBaseline, LOGO_SIZE, "ink"));
parts.push(
  `<rect class="en" x="${tileCx - LOGO_UNDERLINE.width / 2}" y="${(logoBaseline + logoInk.bottom + LOGO_UNDERLINE.gap).toFixed(1)}" width="${LOGO_UNDERLINE.width}" height="${LOGO_UNDERLINE.height}" rx="${LOGO_UNDERLINE.height / 2}"/>`,
);

// 名前: 音節ごとにルビを振り、点線の下線を引く
const nameInk = g.ink(NAME, "bold", NAME_SIZE);
const rubyBaseline = NAME_BASELINE - nameInk.top - RUBY_GAP;
let x = TEXT_X;
for (const [roman, kana] of SYLLABLES) {
  const w = g.width(roman, "bold", NAME_SIZE);
  parts.push(g.draw(roman, "bold", x, NAME_BASELINE, NAME_SIZE, "ink"));
  parts.push(
    g.center(kana, "regular", x + w / 2, rubyBaseline, RUBY_SIZE, "sub"),
  );
  x += w;
}
const nameWidth = x - TEXT_X;
const underlineY = NAME_BASELINE + nameInk.bottom + UNDERLINE_GAP;
const dots = Math.floor(nameWidth / DOT.pitch);
for (let i = 0; i <= dots; i++)
  parts.push(
    `<circle class="line" cx="${(TEXT_X + i * DOT.pitch).toFixed(1)}" cy="${(underlineY + UNDERLINE_HEIGHT / 2).toFixed(1)}" r="${DOT.radius}"/>`,
  );

// 継ぎ目 と、その実線の下線
const kanjiX = x + KANJI_GAP;
const kanjiWidth = g.width(KANJI, "bold", KANJI_SIZE);
parts.push(g.draw(KANJI, "bold", kanjiX, NAME_BASELINE, KANJI_SIZE, "ink"));
parts.push(
  `<rect class="en" x="${kanjiX.toFixed(1)}" y="${underlineY.toFixed(1)}" width="${kanjiWidth.toFixed(1)}" height="${UNDERLINE_HEIGHT}" rx="${UNDERLINE_HEIGHT / 2}"/>`,
);

// コピー
parts.push(g.draw(COPY, "bold", TEXT_X, COPY_BASELINE, COPY_SIZE, "ink"));
parts.push(
  g.draw(SUBCOPY, "regular", TEXT_X, SUBCOPY_BASELINE, SUBCOPY_SIZE, "sub"),
);

const right = Math.max(
  kanjiX + kanjiWidth,
  TEXT_X + g.width(COPY, "bold", COPY_SIZE),
  TEXT_X + g.width(SUBCOPY, "regular", SUBCOPY_SIZE),
);
if (right > WIDTH - TILE_X)
  throw new Error(
    `文字が右の余白に入る: 右端 ${right.toFixed(1)} > ${WIDTH - TILE_X}`,
  );
const copyTop = COPY_BASELINE - g.ink(COPY, "bold", COPY_SIZE).top;
if (underlineY + UNDERLINE_HEIGHT >= copyTop)
  throw new Error(
    `名前の下線 ${(underlineY + UNDERLINE_HEIGHT).toFixed(1)} がコピーの上端 ${copyTop.toFixed(1)} に重なる`,
  );

const label = `tugime（${KANJI}）のロゴと名前。${COPY}${SUBCOPY}`;
await writeImage(
  "hero.svg",
  svgDocument(SOURCE, WIDTH, HEIGHT, label, g, parts.join(""), "auto", STYLE),
);
