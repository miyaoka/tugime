# 開発

## 変換を確かめる

```bash
swift build --product tugime-cli
scripts/fetch-genmai.sh                                                           # 入力メソッドと同じモデルを .zenz/ に用意する
.build/debug/tugime-cli nodewosakujosite,sitewokoukaisuru                         # 入力メソッドと同じ方式で変換した結果
.build/debug/tugime-cli --explain sitewokoukaisuru                                # 区間と評価値（採点の変換）
.build/debug/tugime-cli --typing burauzanankahirakerunda                          # 1 打鍵ずつ打ったときの表示と、未確定の文字列の下の知らせ
swift test
```

`tugime-cli` の他の引数は `tugime-cli --help` で出る。

## 変換の精度を測る

変換の方式・モデル・綴りの表・日英判定の変更は `tugime-eval` で比べる。精度は、問題（AJIMEE-Bench と Mozc の回帰テスト）の読みを利用者の綴りで打ったときに確定する文字列で測る。問題は版を固定して `.eval/` に取得する。CI では動かさない。

```bash
swift build -c release --product tugime-eval
problems=$(scripts/fetch-eval.sh)                                                  # 問題を取得してディレクトリを出す
model=$(scripts/fetch-genmai.sh)                                                   # 入力メソッドと同じモデルのパス
.build/release/tugime-eval accuracy --method azookey --problems "$problems" --out .eval/azookey.jsonl
.build/release/tugime-eval accuracy --method "direct:$model" --problems "$problems" --out .eval/genmai.jsonl
.build/release/tugime-eval compare .eval/azookey.jsonl .eval/genmai.jsonl         # 片方だけが正解した問題
.build/release/tugime-eval keystrokes --method "direct:$model" --problems "$problems" --out .eval/keys.tsv
```

別のモデルを測るときは、Hugging Face の safetensors を GGUF にして、そのパスを `model` にする。

```bash
model=$(scripts/convert-hf-to-gguf.sh <リポジトリ> <コミット> q8_0 <出力名>)
```

引数と終了コードは `tugime-eval` を引数なしで実行すると出る。

## README と docs の図を作り直す

図は `tugime-cli` の出力から SVG に描く。手で書き換えない。字形はフォントから図形にして埋め込み、配色はライトとダークで切り替える（`scripts/lib/svg.ts`）。

```bash
bun install --cwd scripts
bun scripts/make-demo.ts             # README の冒頭のデモ docs/images/demo.svg と demo-compare.svg
bun scripts/make-readme-figures.ts   # docs/images/intro.svg と conversion.svg
bun scripts/make-pipeline.ts         # README の変換の仕組みの図 docs/images/pipeline.svg
```

`make-demo.ts` は、他の入力方式の結果のうち、日本語モードのライブ変換の結果だけを人間が打って確かめた値として持つ。デモの打鍵列を変えたら、その値も打ち直して変える。
