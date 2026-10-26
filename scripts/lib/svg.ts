// README と docs の図を作るスクリプトが共有する部品。tugime-cli の実行と、フォントの字形を図形にして埋め込む SVG の組み立て。
// 文字を図形にするので、見る人の環境のフォントに左右されない。配色は prefers-color-scheme でライトとダークを切り替える
import { dirname, join } from "node:path";
import opentype from "opentype.js";

export const root = join(dirname(import.meta.path), "../..");
export const images = join(root, "docs/images");
export const cli = join(root, ".build/release/tugime-cli");
const COMMAND_TIMEOUT_MS = 300_000;

const started = Date.now();
export const elapsed = () => `${((Date.now() - started) / 1000).toFixed(1)}秒`;

export async function run(command: string[]): Promise<string> {
  const proc = Bun.spawn(command, { cwd: root, stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => proc.kill(), COMMAND_TIMEOUT_MS);
  const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  const code = await proc.exited;
  clearTimeout(timer);
  if (code !== 0) throw new Error(`失敗 (${code}): ${command.join(" ")}\n${stderr.slice(-2000)}`);
  return stdout;
}

export async function step<T>(name: string, task: () => Promise<T>): Promise<T> {
  console.error(`${name} 開始 ${elapsed()}`);
  const result = await task();
  console.error(`${name} 完了 ${elapsed()}`);
  return result;
}

/// 最後の行に出力したパスを返すスクリプトを実行する
async function pathFrom(script: string): Promise<string> {
  return (await run([join(root, "scripts", script)])).trim().split("\n").pop()!;
}

export type Fonts = { bold: opentype.Font; regular: opentype.Font };

/// 表示の変換のモデルとフォントを用意し、tugime-cli を組み立てる
export async function prepare(): Promise<{ model: string; fonts: Fonts }> {
  const model = await step("表示の変換のモデルの用意", () => pathFrom("fetch-genmai.sh"));
  const fontDir = await step("フォントの用意", () => pathFrom("fetch-fonts.sh"));
  await step("tugime-cli の組み立て", () => run(["swift", "build", "-c", "release", "--product", "tugime-cli"]));
  const fonts = {
    bold: opentype.loadSync(join(fontDir, "LINESeedJP-Bold.ttf")),
    regular: opentype.loadSync(join(fontDir, "LINESeedJP-Regular.ttf")),
  };
  return { model, fonts };
}

/// --live の出力から、打鍵列ごとの表示を読む。変換エンジンのログも標準出力に混ざるので、渡した打鍵列で始まる行だけを読む
export function readLive(stdout: string, inputs: string[]): string[] {
  const lines = new Map<string, string>();
  for (const line of stdout.split("\n")) {
    const tab = line.indexOf("\t");
    if (tab > 0) lines.set(line.slice(0, tab), line.slice(tab + 1));
  }
  return inputs.map((i) => {
    const shown = lines.get(i);
    if (shown === undefined) throw new Error(`--live の結果が無い: ${i}`);
    return shown;
  });
}

export type Kind = "J" | "E" | "P";
export type Segment = { kind: Kind; s: number; e: number; output: string };
export type Span = { s: number; e: number; after: string; kind: "J" | "E"; output: string; score: number };

/// --explain と --lattice の区間の表記 K[打鍵→出力 点]
const segmentPattern = /([JEP])\[(.*?)→(.*?) (-?[\d.]+)\]/g;

/// --explain の区間の並びを、打鍵列の位置と出力にする
export function parseSegments(described: string): Segment[] {
  let pos = 0;
  return [...described.matchAll(segmentPattern)].map((m) => {
    const segment = { kind: m[1] as Kind, s: pos, e: pos + m[2].length, output: m[3] };
    pos = segment.e;
    return segment;
  });
}

/// 打鍵列ごとの、区切りの採点で比べた区間の候補
export async function readLattices(inputs: string[]): Promise<Map<string, Span[]>> {
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

export type Path = { total: number; spans: Span[] };

/// 区間の候補を、直前の区間の種類が合うようにつないだ並びのうち、合計の最も高いもの。allow で使える区間を、must で含むべき区間を絞る
export function bestPath(spans: Span[], length: number, allow: (s: Span) => boolean, must: (s: Span) => boolean = () => true): Path | undefined {
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

/// 英字・数字・半角の記号は打ったまま残った文字なので英語の色、それ以外は日本語の色
export const kindOf = (ch: string) => (/[\x21-\x7e]/.test(ch) ? "en" : "ink");

export type FontName = keyof Fonts;
export type Paint = string | ((ch: string, index: number) => string);

/// 1 枚の SVG で使った字形を 1 回だけ <defs> に入れ、<use> で並べる
export class Glyphs {
  private defs = new Map<string, string>();
  constructor(private fonts: Fonts) {}

  /// draw が並べる幅。draw は 1 字ずつ字形の送り幅で並べるので、カーニングや合字を含む getAdvanceWidth では測らない
  width(text: string, font: FontName, size: number): number {
    const f = this.fonts[font];
    return [...text].reduce((w, ch) => w + (f.charToGlyph(ch).advanceWidth * size) / f.unitsPerEm, 0);
  }

  /// 文字の間に tracking を足して並べたとき、text の幅が width になる字の大きさ（幅は字の大きさに比例する）
  sizeFor(text: string, font: FontName, width: number, tracking: number): number {
    const gaps = [...text].length - 1;
    const size = (width - tracking * gaps) / this.width(text, font, 1);
    if (size <= 0) throw new Error(`${text} は字間 ${tracking} で幅 ${width.toFixed(1)} に収まらない`);
    return size;
  }

  /// text を x から並べた <use> の列。paint は class 名か、1 文字ずつ class 名を返す関数。tracking は文字ごとに足す字間
  draw(text: string, font: FontName, x: number, baseline: number, size: number, paint: Paint, tracking = 0): string {
    const f = this.fonts[font];
    const scale = size / f.unitsPerEm;
    return [...text]
      .map((ch, index) => {
        const glyph = f.charToGlyph(ch);
        if (glyph.index === 0) throw new Error(`フォント ${font} に字形が無い: ${ch}`);
        const id = `${font[0]}${ch.codePointAt(0)!.toString(16)}`;
        if (!this.defs.has(id)) this.defs.set(id, `<path id="${id}" d="${glyph.getPath(0, 0, f.unitsPerEm).toPathData(1)}"/>`);
        const cls = typeof paint === "string" ? paint : paint(ch, index);
        const use = `<use href="#${id}" class="${cls}" transform="translate(${x.toFixed(1)} ${baseline.toFixed(1)}) scale(${scale.toFixed(5)})"/>`;
        x += glyph.advanceWidth * scale + tracking;
        return use;
      })
      .join("");
  }

  /// 中央 cx に揃えて並べる
  center(text: string, font: FontName, cx: number, baseline: number, size: number, paint: Paint): string {
    return this.draw(text, font, cx - this.width(text, font, size) / 2, baseline, size, paint);
  }

  /// 右端 right に揃えて並べる
  right(text: string, font: FontName, right: number, baseline: number, size: number, paint: Paint): string {
    return this.draw(text, font, right - this.width(text, font, size), baseline, size, paint);
  }

  defsXml(): string {
    return [...this.defs.values()].join("");
  }
}

const LIGHT = `
  .bg { fill: #ffffff; } .panel { fill: #f6f8fa; } .sub { fill: #6b7280; } .ink { fill: #111827; } .en { fill: #c2410c; } .key { fill: #4b5563; }
  .bad { fill: #dc2626; } .good { fill: #15803d; } .line { fill: #9ca3af; } .chip { fill: #e5e7eb; }
  .jtint { fill: #e7ecf4; } .etint { fill: #fbe7d8; }`;
const DARK = `
  @media (prefers-color-scheme: dark) {
    .bg { fill: #0d1117; } .panel { fill: #161b22; } .sub { fill: #9ca3af; } .ink { fill: #f3f4f6; } .en { fill: #fb923c; } .key { fill: #d1d5db; }
    .bad { fill: #f87171; } .good { fill: #4ade80; } .line { fill: #6b7280; } .chip { fill: #30363d; }
    .jtint { fill: #1f2937; } .etint { fill: #3b2414; }
  }`;

/// auto は見る人の設定でライトとダークを切り替え、light はダークでもライトの配色のまま描く
export type Scheme = "auto" | "light";

const escapeXml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/// 字形の定義と背景を付けた SVG。body は glyphs で描き終えたものを渡す（<defs> は使った字形から作るため）。label は画像の説明。
/// style は図が足す CSS
export function svgDocument(source: string, width: number, height: number, label: string, glyphs: Glyphs, body: string, scheme: Scheme = "auto", style = ""): string {
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
  const alt = text.match(new RegExp(`!\\[([^\\]]*)\\]\\([^)]*${name.replace(/\./g, "\\.")}\\)`))?.[1];
  if (alt === undefined) throw new Error(`${doc} に ${name} の参照が無い`);
  const missing = values.filter((v) => !alt.includes(v));
  if (missing.length) throw new Error(`${doc} の ${name} の説明文に ${missing.join(" / ")} が無い`);
}

export async function writeImage(name: string, svg: string) {
  await Bun.write(join(images, name), svg);
  console.error(`${name} 書き出し ${(svg.length / 1024).toFixed(0)}KB ${elapsed()}`);
}
