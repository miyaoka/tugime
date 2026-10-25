# tugime

/tsɯɡime/ 継ぎ目

![同じ文 dark mode の配色を変えて、pull request を出しました。を打つとき、ふつうの日本語入力では文字のほかに英数・かな・変換・Enter を 8 回押す。tugime では Space がそのまま空白になり、文字のほかに押すのは最後の Enter だけ](docs/images/intro.png)

macOS の日本語入力。英語が混じった日本語の文を、IME を切らずに一息に変換する。ローマ字の打鍵列から日本語の区間と英語の区間を見分け、日本語はかな漢字に変換し、英語は英字のまま残す。

```
github actionsdetestwohasirasetemergesuru.              →  github actionsでtestを走らせてmergeする。
dark mode nohaisyokuwokaete,pull request wodasimasita.  →  dark mode の配色を変えて、pull request を出しました。
nodewosakujosite,sitewokoukaisuru                       →  nodeを削除して、siteを公開する
```

英語だけの文は、英数に切り替えて打つ。

## 特色

### Space

打っている途中の Space は空白を入れる。ふつうの日本語入力では Space が変換に使われるので、英語の語句の間に空白を入れるには、確定して英数に切り替える必要がある。tugime は打つそばから変換して表示するので、変換の操作を挟まずに打ち進められる。キーの操作は「使い方」の表にある。

### 日英の判定

![設定をhideしたままにする を打ち進めるごとの表示と、その裏で比べた読み方の候補。打鍵列の範囲を日本語や英語として読む候補を挙げ、点の合計が最も高い並びを採る。hide は、打った直後は英語、続けて打つと日本語、最後の打鍵で英語に戻る](docs/images/conversion.png)

利用者のローマ字の綴りで読めない並び（`gl` `pr` `str` など）を含む区間は英語になる。ローマ字として読める英単語（`node` `site` など）は、文の前後から日本語か英語かを決める。英語の後の句読点は、日本語の記号にせず打ったまま残る。

### 学習

打ち方を学習しない。同じ入力と同じ前後の文脈には、常に同じ結果を返す。

### かな漢字変換

表示する変換は、かな漢字変換の言語モデル [genmai-310M](https://huggingface.co/subdiox/genmai-310M) が前の文脈を見て出す。区切りの採点と候補の窓は [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter) が受け持つ。

## 動作環境

Apple Silicon の macOS。動作は macOS 27 でだけ確かめている。

## 安全性

入力メソッドは、どのアプリで打った文字も受け取る。tugime は、偽物を入れないためと、打った内容を外へ出さないために、次のことをしている。

- **導入**: 配布物が tugime のリポジトリで組み立てられたものかを確かめてから入れる。手順は「導入」にある
- **通信しない**: tugime は通信しない。さらに macOS の Sandbox で通信とファイルの読み書きを制限し、tugime に穴があって攻撃されたときの被害を減らす
- **記録しない**: 打ち方を学習せず、打った内容を保存しない
- **パスワード欄**: 安全入力が有効な間は、キーを変換せずにそのままアプリへ渡す

## 導入

改竄されていない tugime を安全に入れるために、以下では、配布物が tugime の release workflow で組み立てられたものかを確かめてから入れる方法を案内する。tugime は Apple の有料の公証を受けていないため、代わりに GitHub 上での署名と[出自の証明](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)を用いる。

入れ方は次の A〜C のどれか 1 つを選ぶ。どれで入れても、初めて入れたときだけ、最後に入力ソースを追加する。

### A. mise で入れる

[mise](https://mise.jdx.dev/) を使うと、mise が配布物を確かめてから入れる。tugime の release workflow が署名していない配布物や、署名のあとで書き換えられた配布物は、mise が入れずに止める。確かめには [packslip](https://packslip.dev/) という仕組みを使う。更新は `mise up` だけでよい。

mise は 2026.10.5 以降を使う。それより前の版は、下のコマンドの `workflow` の指定に対応していない。

```bash
mise use -g 'packslip:github.com/miyaoka/tugime[workflow="release.yml@refs/heads/main",postinstall="\"$MISE_TOOL_INSTALL_PATH/install.sh\" \"$MISE_TOOL_INSTALL_PATH/tugime.app\""]'
```

### B. GitHub CLI で入れる

mise を使わないときは、[GitHub CLI](https://cli.github.com/) で、同じく改竄されていないことを確かめてから入れる。次のコマンドは、一時ディレクトリに最新版を取得し、tugime の release workflow が組み立てたものかを確かめ、確かめられたときだけ展開して入れる。更新するときも同じコマンドでよい。

```bash
dir=$(mktemp -d) &&
gh release download --repo miyaoka/tugime --pattern tugime-macos-arm64.tar.gz --dir "$dir" &&
gh attestation verify "$dir/tugime-macos-arm64.tar.gz" --repo miyaoka/tugime --cert-identity https://github.com/miyaoka/tugime/.github/workflows/release.yml@refs/heads/main &&
tar -xzf "$dir/tugime-macos-arm64.tar.gz" -C "$dir" &&
bash "$dir/install.sh"
```

### C. ソースから組み立てて入れる

Xcode（Swift 6.2 以降）が要る。組み立てのときに genmai-310M の GGUF（約 340MB）を Hugging Face から `.zenz/` に取得する。自分で組み立てるので、出自の確かめは要らない。

```bash
scripts/build-app.sh                    # dist/tugime Dev.app を組み立てて ad-hoc 署名する
./install.sh "dist/tugime Dev.app"      # 配置して登録する
```

組み立てたものは `tugime Dev` という別の入力ソースになり、配布版の tugime と並べて入れられる。

### 入力ソースを追加する

初めて入れたときだけ、ログアウトしてログインし直す。システム設定はログインし直すまで新しい入力ソースを一覧に出さない。その後、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 から、配布版なら `tugime (日本語)`、ソースから組み立てたものなら `tugime Dev (日本語)` を追加する。tugime は自分では入力ソースを有効にしない。

## 使い方

| キー | 動き |
|---|---|
| 英字・記号 | 未確定の文字列に足す。打っている途中も変換して表示する。日本語の区間は変換し、英語の区間は英字で表示する |
| Space | 打っている途中は空白を入れる。空白は英語の区間に入り、打ったまま残る。文節を選んでいる間は Shift+Space と同じ |
| Shift+Space | 文節に区切って最初の文節を選ぶ。もう一度押すと候補の窓を出し、その後は次の候補へ進む |
| ↓ / ↑ | 次の候補 / 前の候補 |
| ← / → | 選んでいる文節を縮める / 伸ばす。日本語は 1 かなずつ、英字は 1 文字ずつ。隣の英語・日本語も取り込め、読めない英字を含むと英字のまま残る。区間をまたいで日本語を取り込むときと、区間をまたいで伸ばした文節を縮めるときは、読み切れる綴りずつ（`tte` は `って`）。伸ばした後に縮めると、手放した英字は英字に戻る。日本語の記号にした句読点と記号は取り込まない |
| Shift+← / Shift+→ | 選ぶ文節を左 / 右へ移す。左端から左へ移すと右端、右端から右へ移すと左端を選ぶ |
| Enter | 表示しているとおりに確定する |
| Shift+Enter | 選んでいる文節までを確定し、残りは変換したまま次の文節を選ぶ |
| Esc / Backspace | 候補の窓を閉じる。窓が無ければ文節の選択をやめて、打っている途中の表示に戻る |
| F6 / F7 / F8 / F9 / F10 | 文節を選んでいる間は選んでいる文節を、打っている途中は未確定の文字列全体を、ひらがな / カタカナ / 半角カタカナ / 全角英数 / 打ったままにする |
| 英数 / かな | 英数モード / 日本語モードに切り替える |

- 打っている途中に矢印キーを押すと、Shift+Space を押さなくても最初の文節を選び、そのキーの動きをする
- `,` `.` `?` `!` `~` は、直前が日本語なら `、` `。` `？` `！` `〜` になり、直前が英語なら打ったまま残る
- 入力欄の文字を入力メソッドに渡さないアプリ（Ghostty など）では、tugime で続けて確定した文字列を直前とする。tugime を通さずにアプリへ届くキー（確定の後の Enter や矢印キーなど）を押すと、直前は無いものに戻る
- `[` `]` `/` は常に `「` `」` `・` になる。`zh` `zj` `zk` `zl` は `←` `↓` `↑` `→`、`z.` `z/` `z-` `z[` `z]` は `…` `・` `〜` `『` `』` になる。英字のまま打つときは英数モードにする
- 綴りの表で最後まで読め、日本語の文の中に英字のまま書かれることの少ない綴り（`matte` など）と、読める 2 文字以下の綴り（`ie` など）は日本語になる。英字で残すときは F10 を押す
- パスワード欄などで安全入力が有効な間は、キーを変換せずにアプリへ渡す

## tugime の辞書

既定の辞書に無い語や、別の表記で書きたい語は、tugime の辞書に打鍵で登録する。macOS の「ユーザ辞書」とは別の、tugime だけの辞書である。登録した語は、変換に入れた利用者の語 1 つと同じ強さで、日英の判定と変換に加わる。登録した打鍵がそのまま 1 つの区間になる打ち方では登録した語が出て、それより長い日本語の区間や語が登録した打鍵の範囲をまたいで覆う打ち方（`kai	貝` を登録して `kaisya` と打つ）では、ふだんの変換（会社）のままになる。

辞書は 1 行 1 語のテキストのファイルで、打鍵、表記、区間の種類をタブで区切る。打鍵は、日本語モードで打つとおりの綴り（空白を除く英数字と記号）で書く。区間の種類は `ja`（日本語区間）か `en`（英語区間）で、書かなければ、表記が ASCII だけなら `en`、それ以外は `ja` になる。同じ打鍵に別の表記を何語でも置ける。同じ打鍵と表記の組を 2 回書くと、2 つ目の行は読まない。空行と `#` で始まる行は読まない。

```
# 麻雀
mannzu	萬子
sonohen	そのへん
github	GitHub
cafe	Café
sake	鮭	ja
```

- `ja`: 打鍵を綴りの表でかなに読めれば（`mannzu` は まんず）、その読みの語として変換の候補にし、長い打鍵の途中（`ma-jannnomannzu`）でも効く。英語の語でもある打鍵（`sake`）も日本語の側に寄る。かなに読めない打鍵（`cafe`）は、打鍵とちょうど一致する区間をその語にする
- `en`: 打鍵とちょうど一致する区間を、日本語として読める綴りでも英語区間にし、その表記で表示する

どちらも、打ったままの綴りや元の変換は候補の窓に残る。

メニューバーの入力メニューの「tugime の辞書を編集…」で、辞書をテキストエディタ（プレーンテキストの既定のアプリ）で開く。辞書がまだ無ければ、書式の説明を書いた辞書を作ってから開く。

置き場所は次のとおり。開発版は `io.github.miyaoka.inputmethod.tugime.dev` の側に置く。

```
~/Library/Containers/io.github.miyaoka.inputmethod.tugime/Data/Library/Application Support/tugime/dictionary.tsv
```

保存すると、次に打ち始めたときから効く。読めない行は飛ばし、残りの行を使う。飛ばした行は、Console.app で tugime のログ（カテゴリ dictionary）に行番号つきで出る。

## 綴りの表

既定の綴りは `Sources/TugimeCore/Resources/romaji.tsv` にある。書式はファイルの先頭に書いてある。差し替えたら組み立て直して配置する。

## 開発

```bash
swift build --product tugime-cli
scripts/fetch-genmai.sh                                                           # 入力メソッドと同じモデルを .zenz/ に用意する
.build/debug/tugime-cli nodewosakujosite,sitewokoukaisuru                         # 入力メソッドと同じ方式で変換した結果
.build/debug/tugime-cli --explain sitewokoukaisuru                                # 区間と評価値（採点の変換）
swift test
bun scripts/make-readme-figures.ts                                                # README の図を tugime-cli の出力から作り直す（Chrome が要る）
```

`tugime-cli` の他の引数は `tugime-cli --help` で出る。

変換の方式・モデル・綴りの表・日英判定の変更は `tugime-eval` で比べる。精度は、問題（AJIMEE-Bench と Mozc の回帰テスト）の読みを利用者の綴りで打ったときに確定する文字列で測る。問題は版を固定して `.eval/` に取得する。CI では動かさない。

```bash
swift build -c release --product tugime-eval
problems=$(scripts/fetch-eval.sh)                                                  # 問題を取得してディレクトリを出す
.build/release/tugime-eval accuracy --method azookey --problems "$problems" --out .eval/azookey.jsonl
.build/release/tugime-eval accuracy --method "direct:$model" --problems "$problems" --out .eval/genmai.jsonl
.build/release/tugime-eval compare .eval/azookey.jsonl .eval/genmai.jsonl         # 片方だけが正解した問題
.build/release/tugime-eval keystrokes --method "direct:$model" --problems "$problems" --out .eval/keys.tsv
model=$(scripts/convert-hf-to-gguf.sh <リポジトリ> <コミット> q8_0 <出力名>)      # Hugging Face の safetensors を GGUF にする
```

引数と終了コードは `tugime-eval` を引数なしで実行すると出る。

## 使っているもの

- [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)（MIT）と既定の辞書
- [genmai-310M](https://huggingface.co/subdiox/genmai-310M)（CC BY-SA 4.0。[zenz-v2.5-medium](https://huggingface.co/Miwa-Keita/zenz-v2.5-medium) を元にしたモデル）と [llama.cpp](https://github.com/azooKey/llama.cpp)（MIT）
- 既定のローマ字の綴り: [Mozc](https://github.com/google/mozc) の `src/data/preedit/romanji-hiragana.tsv`（BSD 3 条項。ライセンスの全文は `Sources/TugimeCore/Resources/romaji.tsv` の先頭）
- 英語の語の頻度: [wordfreq](https://github.com/rspeer/wordfreq) の日本語データ（CC BY-SA 4.0）
- 英語の綴りらしさを数える語表: macOS 同梱の Webster's Second International（1934 年、著作権切れ）と固有名詞表
