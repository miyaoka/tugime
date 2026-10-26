// README の冒頭のデモを作る。docs/images/demo.svg は打鍵列を 1 打鍵ずつ tugime-cli に渡した表示を順に見せるアニメーション、
// docs/images/demo-compare.svg は同じ打鍵列をほかの方式で打った結果と並べた静止画。
// 使い方: bun install --cwd scripts && bun scripts/make-demo.ts
import assert from "node:assert";
import {
  Glyphs,
  assertAlt,
  cli,
  kindOf,
  prepare,
  readLive,
  run,
  step,
  svgDocument,
  writeImage,
} from "./lib/svg";

const SOURCE = "scripts/make-demo.ts";

/// デモの打鍵列
const input = "slackdetodoitazipwokaitousitara,logniijougaatta.";
/// 最後まで打ったときに tugime が表示するはずの文
const expected = "slackで届いたzipを解凍したら、logに異常があった。";
/// 人間が macOS 27 の日本語入力（ライブ変換）で input を打って確定した文。CLI では再現できないので、打って確かめた値を書く
const liveConversionResult =
  "sぁckで届いた自pを解凍したら、ぉgに異常があった。";

const KEY_INTERVAL = 0.14;
/// 打ち終えた文を見せておく秒数
const HOLD_FINAL = 3;
const WIDTH = 900;
const LEFT = 40;
const LABEL_SIZE = 15;
/// 打鍵列の字間。打鍵列の幅は、この字間のまま字の大きさを変えて、表示の文の幅にそろえる
const KEYS_TRACKING = 1.5;
const SHOWN_SIZE = 30;
const COMPARE_SIZE = 22;

/// 正しい文 right に対して、other の文字のうち最長共通部分列に入らないものの位置
function wrongPositions(other: string, right: string): Set<number> {
  const a = [...other];
  const b = [...right];
  const lcs = Array.from({ length: a.length + 1 }, () =>
    new Array<number>(b.length + 1).fill(0),
  );
  /// a[i..] と b[j..] の最長共通部分列の長さ
  const at = (i: number, j: number) => {
    const length = lcs[i]?.[j];
    assert(length !== undefined, `最長共通部分列の表の外: ${i}, ${j}`);
    return length;
  };
  for (let i = a.length - 1; i >= 0; i--) {
    const row = lcs[i];
    assert(row !== undefined);
    for (let j = b.length - 1; j >= 0; j--) {
      row[j] =
        a[i] === b[j]
          ? at(i + 1, j + 1) + 1
          : Math.max(at(i + 1, j), at(i, j + 1));
    }
  }
  const wrong = new Set<number>();
  let i = 0;
  let j = 0;
  while (i < a.length) {
    if (j < b.length && a[i] === b[j]) {
      i++;
      j++;
    } else if (j < b.length && at(i, j + 1) >= at(i + 1, j)) j++;
    else wrong.add(i++);
  }
  return wrong;
}

/// 時刻 start から end（秒、end が無ければ最後まで）だけ見せる。全体は total 秒で繰り返す
function visible(
  start: number,
  end: number | undefined,
  total: number,
): string {
  const t = (s: number) => (s / total).toFixed(4);
  const values = end === undefined ? "0;1;1" : "0;1;0;0";
  const keyTimes =
    end === undefined ? `0;${t(start)};1` : `0;${t(start)};${t(end)};1`;
  return `<animate attributeName="opacity" calcMode="discrete" values="${values}" keyTimes="${keyTimes}" dur="${total}s" repeatCount="indefinite"/>`;
}

const { model, fonts } = await prepare();
const prefixes = [...input].map((_, i) => input.slice(0, i + 1));
const frames = await step("1 打鍵ごとの表示", async () =>
  readLive(
    await run([cli, "--method", `direct:${model}`, "--live", ...prefixes]),
    prefixes,
  ),
);
const final = frames[frames.length - 1];
if (final !== expected)
  throw new Error(
    `最後まで打ったときの表示 ${final} が期待する文 ${expected} と違う`,
  );
const [dictionaryResult] = await step(
  "英語を見分けて辞書と統計で変換",
  async () =>
    readLive(await run([cli, "--method", "azookey", "--live", input]), [input]),
);
assert(dictionaryResult !== undefined);
if (dictionaryResult === expected)
  throw new Error(
    `英語を見分けて辞書と統計で変換しても ${expected} になり、比べる意味が無い`,
  );
await assertAlt("README.md", "demo.svg", [input, expected]);
await assertAlt("README.md", "demo-compare.svg", [
  expected,
  liveConversionResult,
  dictionaryResult,
]);

// アニメーション: 打鍵列と、1 打鍵ごとの tugime の表示
{
  const g = new Glyphs(fonts);
  const total = +(frames.length * KEY_INTERVAL + HOLD_FINAL).toFixed(2);
  const keysY = 82;
  const shownY = 150;
  // 打ち終えたときの打鍵列の幅を、表示の文の幅にそろえる。字の大きさは全コマで同じにする
  const keysSize = g.sizeFor(
    input,
    "bold",
    g.width(expected, "bold", SHOWN_SIZE),
    KEYS_TRACKING,
  );
  const frameXml = frames
    .map((shown, i) => {
      const prefix = prefixes[i];
      assert(prefix !== undefined, `${i + 1} 打鍵目の打鍵列が無い`);
      const start = i * KEY_INTERVAL;
      const end = i === frames.length - 1 ? undefined : start + KEY_INTERVAL;
      const width = g.width(shown, "bold", SHOWN_SIZE);
      return `<g opacity="0">${visible(start, end, total)}${g.draw(prefix, "bold", LEFT, keysY, keysSize, "key", KEYS_TRACKING)}${g.draw(shown, "bold", LEFT, shownY, SHOWN_SIZE, kindOf)}<rect class="line" x="${LEFT}" y="${shownY + 10}" width="${width.toFixed(1)}" height="2"/></g>`;
    })
    .join("");
  const title = g.draw("tugime", "bold", LEFT, 36, LABEL_SIZE, "sub");
  const label = `${input} を 1 打鍵ずつ打つと、tugime は打つそばから変換して ${expected} と表示する`;
  await writeImage(
    "demo.svg",
    svgDocument(SOURCE, WIDTH, 190, label, g, title + frameXml),
  );
}

// 静止画: 同じ打鍵列を打った最終結果を方式ごとに並べ、tugime の結果と違う文字を強調する
{
  const g = new Glyphs(fonts);
  const marked = (text: string) => {
    const wrong = wrongPositions(text, expected);
    return (_: string, index: number) => (wrong.has(index) ? "bad" : "ink");
  };
  const rows: [string, string, ReturnType<typeof marked> | typeof kindOf][] = [
    ["tugime", expected, kindOf],
    [
      "日本語モードのライブ変換",
      liveConversionResult,
      marked(liveConversionResult),
    ],
    [
      "英語を見分けて辞書と統計で変換",
      dictionaryResult,
      marked(dictionaryResult),
    ],
  ];
  const keysY = 40;
  const top = 92;
  const rowGap = 74;
  const keysSize = g.sizeFor(
    input,
    "bold",
    g.width(expected, "bold", COMPARE_SIZE),
    KEYS_TRACKING,
  );
  const body =
    g.draw(input, "bold", LEFT, keysY, keysSize, "key", KEYS_TRACKING) +
    rows
      .map(
        ([name, text, paint], row) =>
          g.draw(name, "bold", LEFT, top + row * rowGap, LABEL_SIZE, "sub") +
          g.draw(
            text,
            "bold",
            LEFT,
            top + row * rowGap + 32,
            COMPARE_SIZE,
            paint,
          ),
      )
      .join("");
  const height = top + (rows.length - 1) * rowGap + 32 + 30;
  const label = `${input} と打った結果。tugime は ${expected}、日本語モードのライブ変換は ${liveConversionResult}、英語を見分けて辞書と統計で変換すると ${dictionaryResult}`;
  await writeImage(
    "demo-compare.svg",
    svgDocument(SOURCE, WIDTH, height, label, g, body),
  );
}
