# tugime

macOS の日本語入力。ローマ字のまま打つと、日本語の区間と英語の区間を見分け、日本語はかな漢字変換し、英語は英字のまま残す。

```
kyouhagoogledekensaku → 今日はgoogleで検索
```

- 日英の判定は学習しない。同じ入力には常に同じ結果を返す
- 判定は利用者のローマ字の綴りに合わせる。その綴りで読めない並び（`gl` `pr` `c` `l` など）を含む区間は英語になる
- かな漢字変換は [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) を使う

## 動作環境

Apple Silicon の macOS。動作は macOS 27 でだけ確かめている。

## 導入

ソースから組み立てる。Xcode（Swift 6.1 以降）が要る。

```bash
scripts/build-app.sh   # dist/tugime.app を組み立てて ad-hoc 署名する
scripts/install.sh     # ~/Library/Input Methods に配置して登録する
```

配置したら、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 から `tugime (日本語)` を追加する。tugime は自分では入力ソースを有効にしない。

## 使い方

| キー | 動き |
|---|---|
| 英字・記号 | 未確定の文字列に足す。日本語の区間はかな、英語の区間は英字で表示する |
| Space | 変換する。もう一度押すと候補の窓を出し、その後は次の候補へ進む |
| ↓ / ↑ | 次の候補 / 前の候補 |
| ← / → | 候補を選ぶ区間を移る。区間は日本語・英語・句読点の切れ目で、日本語の中は区切り直さない |
| Enter | 表示しているとおりに確定する。Space を押していなければ読みのまま確定する |
| Esc / Backspace | 候補の窓を閉じる。窓が無ければ変換をやめて読みに戻る |
| F6 / F7 / F8 / F9 / F10 | 未確定の文字列全体を、ひらがな / カタカナ / 半角カタカナ / 全角英数 / 打ったままにする |
| 英数 / かな | 英数モード / 日本語モードに切り替える |

- `,` `.` `?` `!` は、直前が日本語なら `、` `。` `？` `！` になり、直前が英語なら打ったまま残る
- 綴りの表で最後まで読めて英語の語表に無い綴り（`ime` `exe` など）と、読める 2 文字以下の綴り（`ie` など）は日本語になる。英字で残すときは F10 を押す
- パスワード欄などで安全入力が有効な間は、キーを変換せずにアプリへ渡す

## 綴りの表

既定の綴りは `Sources/TugimeCore/Resources/romaji.tsv` にある。書式はファイルの先頭に書いてある。差し替えたら組み立て直して配置する。

## 開発

```bash
swift build -c release --product tugime-cli
.build/release/tugime-cli kyouhagoogledekensaku          # 変換結果
.build/release/tugime-cli --explain kyouhagoogle          # 区間と評価値
.build/release/tugime-cli --corpus corpus/examples.tsv    # 例文集の一致件数
swift test
```

`tugime-cli` の他の引数は `tugime-cli --help` で出る。

## 使っているもの

- [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)（MIT）と既定の辞書
- 英語の語表: macOS 同梱の Webster's Second International（1934 年、著作権切れ）と固有名詞表
