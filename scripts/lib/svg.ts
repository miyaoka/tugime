// README と docs の図を作るスクリプトが共有する部品。tugime-cli の実行と、フォントの字形を図形にして埋め込む SVG の組み立て。
// 文字を図形にするので、見る人の環境のフォントに左右されない。配色は prefers-color-scheme でライトとダークを切り替える
import assert from "node:assert";
import { join } from "node:path";
import opentype from "opentype.js";
import { dictionary } from "../fetch-dictionary";
import { fonts as fetchFonts } from "../fetch-fonts";
import { genmai } from "../fetch-genmai";
import { root } from "./root";

export const images = join(root, "docs/images");
export const cli = join(root, ".build/release/tugime-cli");
const COMMAND_TIMEOUT_MS = 300_000;

const started = Date.now();
export const elapsed = () => `${((Date.now() - started) / 1000).toFixed(1)}秒`;

export async function run(command: string[]): Promise<string> {
  const proc = Bun.spawn(command, {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill(), COMMAND_TIMEOUT_MS);
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const code = await proc.exited;
  clearTimeout(timer);
  if (code !== 0)
    throw new Error(
      `失敗 (${code}): ${command.join(" ")}\n${stderr.slice(-2000)}`,
    );
  return stdout;
}

export async function step<T>(
  name: string,
  task: () => Promise<T>,
): Promise<T> {
  console.error(`${name} 開始 ${elapsed()}`);
  const result = await task();
  console.error(`${name} 完了 ${elapsed()}`);
  return result;
}

export type Fonts = { bold: opentype.Font; regular: opentype.Font };

/// 図の字形を取り出すフォントを用意して読み込む
export async function loadFonts(): Promise<Fonts> {
  const paths = await step("フォントの用意", fetchFonts);
  return {
    bold: opentype.loadSync(paths.bold),
    regular: opentype.loadSync(paths.regular),
  };
}

/// 表示の変換のモデルとシステム辞書を用意し、tugime-cli を組み立てる。モデルのパスを返す
export async function prepareCli(): Promise<string> {
  const model = await step("表示の変換のモデルの用意", genmai);
  await step("システム辞書の用意", dictionary);
  await step("tugime-cli の組み立て", () =>
    run(["swift", "build", "-c", "release", "--product", "tugime-cli"]),
  );
  return model;
}

/// tugime-cli とフォントを用意する
export async function prepare(): Promise<{ model: string; fonts: Fonts }> {
  const model = await prepareCli();
  return { model, fonts: await loadFonts() };
}

/// tugime-cli の標準出力を行に分ける。出力は改行で終わり、途中に空行を含まない
export function outputLines(stdout: string, option: string): string[] {
  if (stdout === "") return [];
  if (!stdout.endsWith("\n"))
    throw new Error(`${option} の出力が改行で終わらない`);
  const lines = stdout.slice(0, -1).split("\n");
  if (lines.includes("")) throw new Error(`${option} の出力に空行がある`);
  return lines;
}

/// 打鍵列ごとに 1 行の結果を出すオプション（--live・--whole）の出力から、打鍵列ごとの結果を読む
export function readPerInput(
  option: "--live" | "--whole",
  stdout: string,
  inputs: string[],
): { input: string; shown: string }[] {
  const lines = new Map<string, string>();
  for (const line of outputLines(stdout, option)) {
    const tab = line.indexOf("\t");
    const input = line.slice(0, tab);
    if (tab <= 0 || !inputs.includes(input))
      throw new Error(`${option} の行を読めない: ${line}`);
    lines.set(input, line.slice(tab + 1));
  }
  return inputs.map((input) => {
    const shown = lines.get(input);
    if (shown === undefined)
      throw new Error(`${option} の結果が無い: ${input}`);
    return { input, shown };
  });
}

export type Kind = "J" | "E" | "P";
/// tugime-cli が区間の種類に出す文字と、その種類
const SEGMENT_KINDS = new Map<string, Kind>([
  ["J", "J"],
  ["E", "E"],
  ["P", "P"],
]);
const SPAN_KINDS = new Map<string, Span["kind"]>([
  ["J", "J"],
  ["E", "E"],
]);
export type Segment = { kind: Kind; s: number; e: number; output: string };
export type Span = {
  s: number;
  e: number;
  after: string;
  kind: "J" | "E";
  output: string;
  score: number;
};

/// --explain と --lattice の区間の表記 K[打鍵→出力 点]
const segmentPattern = /([JEP])\[(.*?)→(.*?) (-?[\d.]+)\]/g;

/// --explain の区間の並びを、打鍵列の位置と出力にする
export function parseSegments(described: string): Segment[] {
  const matches = [...described.matchAll(segmentPattern)];
  if (matches.map((m) => m[0]).join(" ") !== described)
    throw new Error(`区間の表記を読めない: ${described}`);
  let pos = 0;
  return matches.map((m) => {
    const [whole, letter, keys, output] = m;
    const kind = letter === undefined ? undefined : SEGMENT_KINDS.get(letter);
    assert(
      kind !== undefined && keys !== undefined && output !== undefined,
      `区間の表記を読めない: ${whole}`,
    );
    const segment = {
      kind,
      s: pos,
      e: pos + keys.length,
      output,
    };
    pos = segment.e;
    return segment;
  });
}

/// 打鍵列ごとの、区切りの採点で採った区間の並び
export async function readExplains(inputs: string[]): Promise<Segment[][]> {
  const lines = outputLines(
    await run([cli, "--explain", ...inputs]),
    "--explain",
  );
  if (lines.length !== inputs.length)
    throw new Error(
      `--explain の行数 ${lines.length} が ${inputs.length} と合わない`,
    );
  return lines.map((l) => {
    const [, described, ...rest] = l.split("\t");
    if (!described || rest.length > 0)
      throw new Error(`--explain の行を読めない: ${l}`);
    return parseSegments(described);
  });
}

/// 打鍵列ごとの、区切りの採点で比べた区間の候補
export async function readLattices(
  inputs: string[],
): Promise<Map<string, Span[]>> {
  const out = await run([cli, "--lattice", ...inputs]);
  const lattices = new Map<string, Span[]>();
  let current: Span[] | undefined;
  for (const line of outputLines(out, "--lattice")) {
    const input = line.match(/^== (\S+)\t/)?.[1];
    if (input !== undefined) {
      current = [];
      lattices.set(input, current);
      continue;
    }
    const [s, e, after, letter, , output, score, ...rest] = line.split("\t");
    const kind = letter === undefined ? undefined : SPAN_KINDS.get(letter);
    if (
      s === undefined ||
      !/^\d+$/.test(s) ||
      e === undefined ||
      !/^\d+$/.test(e) ||
      after === undefined ||
      kind === undefined ||
      output === undefined ||
      score === undefined ||
      !/^-?\d+(\.\d+)?(e-?\d+)?$/.test(score) ||
      rest.length > 0
    )
      throw new Error(`--lattice の候補の行を読めない: ${line}`);
    if (!current) throw new Error(`== の行より前に候補がある: ${line}`);
    current.push({
      s: +s,
      e: +e,
      after,
      kind,
      output,
      score: +score,
    });
  }
  for (const i of inputs)
    if (!lattices.get(i)?.length)
      throw new Error(`--lattice の候補が無い: ${i}`);
  return lattices;
}

export type Path = { total: number; spans: Span[] };

/// 区間の候補を、直前の区間の種類が合うようにつないだ、打鍵列の length 文字目までの並びのうち、合計の最も高いもの。
/// length を超える区間は使わない。allow で使える区間を、must で含むべき区間を絞る
export function bestPath(
  spans: Span[],
  length: number,
  allow: (s: Span) => boolean,
  must: (s: Span) => boolean = () => true,
): Path | undefined {
  /// 打鍵列の位置ごとに、最後の区間の種類と must を満たしたかの組で、合計の最も高い並び
  const table: Map<string, Path & { kind: string; hit: boolean }>[] =
    Array.from({ length: length + 1 }, () => new Map());
  const at = (pos: number) => {
    const cells = table[pos];
    // length を超える区間は使わないので、0 から length までの位置だけを読む
    assert(cells !== undefined, `区間の位置 ${pos} が表の外`);
    return cells;
  };
  at(0).set("-|false", { total: 0, spans: [], kind: "-", hit: false });
  for (let pos = 0; pos < length; pos++) {
    for (const cell of at(pos).values()) {
      for (const span of spans) {
        if (
          span.s !== pos ||
          span.e > length ||
          span.after !== cell.kind ||
          !allow(span)
        )
          continue;
        const hit = cell.hit || must(span);
        const total = cell.total + span.score;
        const k = `${span.kind}|${hit}`;
        const existing = at(span.e).get(k);
        if (!existing || existing.total < total)
          at(span.e).set(k, {
            total,
            spans: [...cell.spans, span],
            kind: span.kind,
            hit,
          });
      }
    }
  }
  return [...at(length).values()]
    .filter((c) => c.hit)
    .sort((a, b) => b.total - a.total)[0];
}

/// 英字・数字・半角の記号は打ったまま残った文字なので英語の色、それ以外は日本語の色
export const kindOf = (ch: string) => (/[\x21-\x7e]/.test(ch) ? "en" : "ink");

export type FontName = keyof Fonts;
/// <defs> に入れる字形の id の頭。太さごとに字形が違うので分ける
const FONT_ID: Record<FontName, string> = { bold: "b", regular: "r" };
export type Paint = string | ((ch: string, index: number) => string);

/// 字形の送り幅
function advance(glyph: opentype.Glyph, ch: string): number {
  if (glyph.advanceWidth === undefined)
    throw new Error(`字形に送り幅が無い: ${ch}`);
  return glyph.advanceWidth;
}

/// 1 枚の SVG で使った字形を 1 回だけ <defs> に入れ、<use> で並べる
export class Glyphs {
  private defs = new Map<string, string>();
  constructor(private fonts: Fonts) {}

  /// draw が並べる幅。draw は 1 字ずつ字形の送り幅で並べるので、カーニングや合字を含む getAdvanceWidth では測らない
  width(text: string, font: FontName, size: number): number {
    const f = this.fonts[font];
    return [...text].reduce(
      (w, ch) => w + (advance(f.charToGlyph(ch), ch) * size) / f.unitsPerEm,
      0,
    );
  }

  /// text を x から並べたとき、right を越えるなら止める
  private assertFits(
    text: string,
    font: FontName,
    size: number,
    x: number,
    right: number,
  ): void {
    if (x + this.width(text, font, size) > right)
      throw new Error(`${text} が右端 ${right.toFixed(1)} を越える`);
  }

  /// right を越えないことを確かめてから、text を x から並べる
  drawWithin(
    text: string,
    font: FontName,
    x: number,
    baseline: number,
    size: number,
    paint: Paint,
    right: number,
  ): string {
    this.assertFits(text, font, size, x, right);
    return this.draw(text, font, x, baseline, size, paint);
  }

  /// text の字形が描かれる範囲の、ベースラインから上の高さ top と下の深さ bottom（下に出ないなら負）
  ink(
    text: string,
    font: FontName,
    size: number,
  ): { top: number; bottom: number } {
    const f = this.fonts[font];
    const scale = size / f.unitsPerEm;
    const boxes = [...text].map((ch) => f.charToGlyph(ch).getBoundingBox());
    return {
      top: Math.max(...boxes.map((b) => b.y2)) * scale,
      bottom: -Math.min(...boxes.map((b) => b.y1)) * scale,
    };
  }

  /// 文字の間に tracking を足して並べたとき、text の幅が width になる字の大きさ（幅は字の大きさに比例する）
  sizeFor(
    text: string,
    font: FontName,
    width: number,
    tracking: number,
  ): number {
    const gaps = [...text].length - 1;
    const size = (width - tracking * gaps) / this.width(text, font, 1);
    if (size <= 0)
      throw new Error(
        `${text} は字間 ${tracking} で幅 ${width.toFixed(1)} に収まらない`,
      );
    return size;
  }

  /// text を x から並べた <use> の列。paint は class 名か、1 文字ずつ class 名を返す関数。tracking は文字ごとに足す字間
  draw(
    text: string,
    font: FontName,
    x: number,
    baseline: number,
    size: number,
    paint: Paint,
    tracking = 0,
  ): string {
    const f = this.fonts[font];
    const scale = size / f.unitsPerEm;
    return [...text]
      .map((ch, index) => {
        const glyph = f.charToGlyph(ch);
        if (glyph.index === 0)
          throw new Error(`フォント ${font} に字形が無い: ${ch}`);
        const code = ch.codePointAt(0);
        assert(code !== undefined, `字形を引く文字が空: ${text}`);
        const id = `${FONT_ID[font]}${code.toString(16)}`;
        if (!this.defs.has(id))
          this.defs.set(
            id,
            `<path id="${id}" d="${glyph.getPath(0, 0, f.unitsPerEm).toPathData(1)}"/>`,
          );
        const cls = typeof paint === "string" ? paint : paint(ch, index);
        const use = `<use href="#${id}" class="${cls}" transform="translate(${x.toFixed(1)} ${baseline.toFixed(1)}) scale(${scale.toFixed(5)})"/>`;
        x += advance(glyph, ch) * scale + tracking;
        return use;
      })
      .join("");
  }

  /// 中央 cx に揃えて並べる
  center(
    text: string,
    font: FontName,
    cx: number,
    baseline: number,
    size: number,
    paint: Paint,
  ): string {
    return this.draw(
      text,
      font,
      cx - this.width(text, font, size) / 2,
      baseline,
      size,
      paint,
    );
  }

  /// 右端 right に揃えて並べる
  right(
    text: string,
    font: FontName,
    right: number,
    baseline: number,
    size: number,
    paint: Paint,
  ): string {
    return this.draw(
      text,
      font,
      right - this.width(text, font, size),
      baseline,
      size,
      paint,
    );
  }

  defsXml(): string {
    return [...this.defs.values()].join("");
  }
}

const LIGHT = `
  .bg { fill: #ffffff; } .panel { fill: #f6f8fa; } .sub { fill: #6b7280; } .ink { fill: #111827; } .en { fill: #c2410c; } .key { fill: #4b5563; }
  .bad { fill: #dc2626; } .good { fill: #15803d; } .line { fill: #9ca3af; } .chip { fill: #e5e7eb; }
  .jtint { fill: #e7ecf4; } .etint { fill: #fbe7d8; }
  .field { fill: #ffffff; stroke: #d0d7de; } .dash { stroke: #9ca3af; stroke-width: 2; stroke-dasharray: 6 5; }`;
const DARK = `
  @media (prefers-color-scheme: dark) {
    .bg { fill: #0d1117; } .panel { fill: #161b22; } .sub { fill: #9ca3af; } .ink { fill: #f3f4f6; } .en { fill: #fb923c; } .key { fill: #d1d5db; }
    .bad { fill: #f87171; } .good { fill: #4ade80; } .line { fill: #6b7280; } .chip { fill: #30363d; }
    .jtint { fill: #1f2937; } .etint { fill: #3b2414; }
    .field { fill: #0d1117; stroke: #30363d; } .dash { stroke: #6b7280; }
  }`;

/// アプリの入力欄。上端の帯に caption、未確定の文字列 text と下線、あれば下に foot を描く。描いた要素と下端を返す
export function inputField(
  g: Glyphs,
  x: number,
  top: number,
  width: number,
  caption: string,
  text: string,
  size: number,
  foot?: string,
): { parts: string[]; bottom: number } {
  const textY = top + 48 + size;
  const lineY = textY + 12;
  const bottom = foot ? lineY + 30 : lineY + 22;
  const parts = [
    `<rect class="field" x="${x}" y="${top}" width="${width}" height="${bottom - top}" rx="12"/>`,
    `<path class="panel" d="M${x + 1} ${top + 30} V${top + 12} a11 11 0 0 1 11 -11 H${x + width - 12} a11 11 0 0 1 11 11 V${top + 30} Z"/>`,
    ...[0, 1, 2].map(
      (k) =>
        `<circle class="sub" cx="${x + 18 + k * 18}" cy="${top + 16}" r="5"/>`,
    ),
    g.draw(caption, "regular", x + 74, top + 21, 13, "sub"),
    g.drawWithin(text, "bold", x + 26, textY, size, kindOf, x + width - 14),
    `<line class="dash" x1="${x + 14}" y1="${lineY}" x2="${x + width - 14}" y2="${lineY}"/>`,
  ];
  if (foot) parts.push(g.draw(foot, "regular", x + 14, lineY + 20, 12, "sub"));
  return { parts, bottom };
}

/// auto は見る人の設定でライトとダークを切り替え、light はダークでもライトの配色のまま描く
export type Scheme = "auto" | "light";

const escapeXml = (s: string) =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

/// 字形の定義と背景を付けた SVG。body は glyphs で描き終えたものを渡す（<defs> は使った字形から作るため）。label は画像の説明。
/// style は図が足す CSS
export function svgDocument(
  source: string,
  width: number,
  height: number,
  label: string,
  glyphs: Glyphs,
  body: string,
  scheme: Scheme = "auto",
  style = "",
): string {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="img" aria-label="${escapeXml(label)}">
<!-- ${source} が生成する。直接編集しない。字形は LINE Seed JP（SIL Open Font License 1.1） -->
<style>${LIGHT}${scheme === "auto" ? DARK : ""}${style}
</style>
<defs>${glyphs.defsXml()}</defs>
<rect class="bg" width="${width}" height="${height}" rx="12"/>
${body}
</svg>
`;
}

/// Markdown の文書 doc で画像 name を参照する説明文（alt）に、生成した値 values がすべて含まれるかを確かめる。
/// 説明文は手で書くので、変換の結果が変わったときに図だけ変わって説明文が古くなるのを止める
export async function assertAlt(doc: string, name: string, values: string[]) {
  const text = await Bun.file(join(root, doc)).text();
  const alt = text.match(
    new RegExp(`!\\[([^\\]]*)\\]\\([^)]*${name.replace(/\./g, "\\.")}\\)`),
  )?.[1];
  if (alt === undefined) throw new Error(`${doc} に ${name} の参照が無い`);
  const missing = values.filter((v) => !alt.includes(v));
  if (missing.length)
    throw new Error(
      `${doc} の ${name} の説明文に ${missing.join(" / ")} が無い`,
    );
}

export async function writeImage(name: string, svg: string) {
  await Bun.write(join(images, name), svg);
  console.error(
    `${name} 書き出し ${(svg.length / 1024).toFixed(0)}KB ${elapsed()}`,
  );
}
