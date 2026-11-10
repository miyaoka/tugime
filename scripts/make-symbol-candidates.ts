// 記号の候補の表（Sources/TugimeCore/Resources/symbol-candidates.tsv）を、Mozc の記号辞書から作る。
// 読みごとの記号の並びと読みの書き換えは、Mozc の記号辞書を作る gen_symbol_rewriter_dictionary_main.cc と同じにする。
// - 記号は、最初の文字の順位（ordering_rule.txt の行の順、次に sorting_map.tsv の行の順）で並べ、同じ順位なら UTF-8 のバイト列の順にする
// - どちらにも無い文字の記号は、記号のすべての文字が JIS X 0208 か許可リストの文字なら順位 0、そうでなければ最後
// - 読みは、全角の英数記号を fullwidthascii-halfwidthascii.tsv で半角にし、ASCII の大文字を小文字にする
// Mozc は引くときに同じ書き換えをするが、tugime の表は書き換える前の 1 文字の読みでも引けるように行を足す。
// tugime が引く鍵は、記号と句読点の文節の 1 文字の記号と、日本語の文節のひらがなの読みだけで、書き換えが要るのは 1 文字の記号だけだから。
// 版は lib/mozc.ts の Mozc のコミットで固定する。使い方: bun scripts/make-symbol-candidates.ts
import { join } from "node:path";
import { fetchMozc, mozcSource } from "./lib/mozc";
import { root } from "./lib/root";

/// Mozc の src からのパスと SHA-256
const files = {
  symbols: [
    "data/symbol/symbol.tsv",
    "bc68b032a195f203dccba6f95667424199ba9b185fee2be64eeaa959253c097a",
  ],
  orderingRule: [
    "data/symbol/ordering_rule.txt",
    "64350ef978280900ac8b9d1a9207e85b405ef91677b8c8ed6fc05794b9dfecb8",
  ],
  sortingMap: [
    "data/rules/sorting_map.tsv",
    "f0d3a92a2f56c966558449dfe7f61ed76217475172c11c40072e5c70589c6221",
  ],
  halfwidth: [
    "data/preedit/fullwidthascii-halfwidthascii.tsv",
    "be2444d15818892063f5dd4de428586f9f342e2afb649434ea6a23a9036ec3a7",
  ],
  generator: [
    "rewriter/gen_symbol_rewriter_dictionary_main.cc",
    "d29807cbaa478a22e5c8f2315e050a875844bf2b555281fd5c3f5c21b8115d2a",
  ],
} as const;

/// JIS X 0208 でも許可リストでもない文字を含む記号の順位（Mozc の USHRT_MAX）
const LAST = 0xffff;
/// gen_symbol_rewriter_dictionary_main.cc の kJisX0208Chars の文字の数（ソースのコメントの「6,879 characters」）
const JIS_X_0208_COUNT = 6879;
/// 許可リストの文字の数（ASCII の 128 字、半角カナの U+FF61〜U+FF9F の 63 字、個別の 9 字）
const ALLOW_LISTED_COUNT = 128 + 63 + 9;

await fetchMozc(Object.values(files));
const read = (path: string) => Bun.file(join(mozcSource, path)).text();

/// Mozc の GetJisX0208OrAllowListedMap が立てる文字。ソースの kJisX0208Chars の配列と、許可リストの範囲と個別の文字を読む
async function jisX0208OrAllowListed(): Promise<Set<number>> {
  const source = await read(files.generator[0]);
  const body = source.match(/kJisX0208Chars\[\] = \{([^}]*)\}/)?.[1];
  if (body === undefined)
    throw new Error("kJisX0208Chars の配列が見つからない");
  const jis = [...body.matchAll(/0x([0-9a-f]+)/g)].map((m) =>
    Number.parseInt(m[1]!, 16),
  );
  if (jis.length !== JIS_X_0208_COUNT)
    throw new Error(`kJisX0208Chars が ${jis.length} 字`);
  const allowed: number[] = [];
  for (const m of source.matchAll(
    /codepoint = 0x([0-9a-f]+); codepoint <= 0x([0-9a-f]+);/g,
  )) {
    for (
      let c = Number.parseInt(m[1]!, 16);
      c <= Number.parseInt(m[2]!, 16);
      c++
    )
      allowed.push(c);
  }
  for (const m of source.matchAll(/map\.set\(0x([0-9a-f]+)\);/g))
    allowed.push(Number.parseInt(m[1]!, 16));
  if (allowed.length !== ALLOW_LISTED_COUNT)
    throw new Error(`許可リストが ${allowed.length} 字`);
  return new Set([...jis, ...allowed]);
}
const jisSet = await jisX0208OrAllowListed();

/// 記号の最初の文字ごとの順位。ordering_rule.txt の行の順、次に sorting_map.tsv の行の順（Mozc の CreateSortingKeyMap）
const rank = new Map<string, number>();
let next = 0;
for (const line of (await read(files.orderingRule[0])).split("\n")) {
  // # だけの行は # という記号の行
  if (line === "" || (line.startsWith("#") && line.length > 1)) continue;
  if (!rank.has(line)) rank.set(line, next);
  next++;
}
for (const line of (await read(files.sortingMap[0])).split("\n")) {
  if (line === "" || line.startsWith("#")) continue;
  // Mozc と同じく 1 列目を文字の番号として読む
  const [code] = line.split(/[\t ]+/);
  if (code === undefined)
    throw new Error(`sorting_map.tsv の行を読めない: ${line}`);
  const char = String.fromCodePoint(Number.parseInt(code, 16));
  if (rank.has(char)) continue;
  rank.set(char, next++);
}

/// 記号の順位（Mozc の AddSymbolToDictionary）
function order(value: string): number {
  const [first] = [...value];
  const ranked = first === undefined ? undefined : rank.get(first);
  if (ranked !== undefined) return ranked;
  // Mozc は文字（char32_t）を Char16BitMap::test(char16_t) に渡すので、下位 16 ビットで引く
  return [...value].every((c) => jisSet.has(c.codePointAt(0)! & 0xffff))
    ? 0
    : LAST;
}

/// 全角の英数記号から半角への書き換え（Mozc の FullWidthAsciiToHalfWidthAscii）
const halfwidth = new Map<string, string>();
for (const line of (await read(files.halfwidth[0])).split("\n")) {
  if (line === "") continue;
  const [full, half] = line.split("\t");
  if (full === undefined || half === undefined)
    throw new Error(
      `fullwidthascii-halfwidthascii.tsv の行を読めない: ${line}`,
    );
  halfwidth.set(full, half);
}

/// 読みの書き換え。全角の英数記号を半角にし、ASCII の大文字を小文字にする（Mozc の Lookup と AddSymbolToDictionary）
function normalize(key: string): string {
  return [...key]
    .map((c) => halfwidth.get(c) ?? c)
    .join("")
    .replace(/[A-Z]/g, (c) => c.toLowerCase());
}

const byKey = new Map<string, { value: string; order: number }[]>();
const seen = new Set<string>();
// 1 行目は列の名前
for (const [index, line] of (await read(files.symbols[0]))
  .split("\n")
  .slice(1)
  .entries()) {
  const [, value, readings] = line.split("\t");
  if (value === undefined || readings === undefined) continue;
  if (value === "" && readings === "") continue;
  if (value === "")
    throw new Error(`symbol.tsv の ${index + 2} 行目に記号が無い: ${line}`);
  // 同じ記号の 2 つ目の行は読まない（Mozc の MakeDictionary）
  if (seen.has(value)) continue;
  seen.add(value);
  const keys = new Set(
    readings
      .split(" ")
      .filter((key) => key !== "")
      .map((key) => normalize(key.replaceAll("　", " "))),
  );
  for (const key of keys) {
    const list = byKey.get(key) ?? [];
    list.push({ value, order: order(value) });
    byKey.set(key, list);
  }
}

/// 同じ順位の記号は UTF-8 のバイト列の順（Mozc の DictionaryGenerator の Token の比較）
const utf8 = (s: string) => Buffer.from(s, "utf8");
const rows = new Map<string, string[]>();
for (const [key, list] of byKey) {
  rows.set(
    key,
    list
      .sort(
        (a, b) =>
          a.order - b.order || Buffer.compare(utf8(a.value), utf8(b.value)),
      )
      .map((entry) => entry.value),
  );
}
// 書き換える前の 1 文字の読みの行。書き換えた読みの行と同じ記号を持つ
for (const [full, half] of halfwidth) {
  const values = rows.get(normalize(half));
  if (values === undefined || rows.has(full)) continue;
  rows.set(full, values);
}

const out = [...rows.keys()]
  .sort((a, b) => Buffer.compare(utf8(a), utf8(b)))
  .map((key) => [key, ...rows.get(key)!].join("\t"));
const target = join(root, "Sources/TugimeCore/Resources/symbol-candidates.tsv");
await Bun.write(target, `${out.join("\n")}\n`);
console.error(`== ${target}: 読み ${out.length} 個`);
