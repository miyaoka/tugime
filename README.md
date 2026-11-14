![tugime（継ぎ目）のロゴと名前。英語まじりの日本語を、継ぎ目なく。日英を自動で区分けし、文脈を汲んで変換する日本語入力](docs/images/hero.svg)

# tugime

英語まじりの日本語も、IME オンのまま切り替えずに打つだけ。macOS の日本語入力です。

/tsɯɡime/ 継ぎ目

![slackdetodoitazipwokaitousitara,logniijougaatta. と 1 打鍵ずつ打つと、tugime は打つそばから変換して slackで届いたzipを解凍したら、logに異常があった。 と表示する](docs/images/demo.svg)

![同じ打鍵列を打った結果。tugime は slackで届いたzipを解凍したら、logに異常があった。、日本語モードのライブ変換は sぁckで届いた自pを解凍したら、ぉgに異常があった。、英語を見分けて辞書と統計で変換すると slackで届いたzipを回答したら、logに異常があった。](docs/images/demo-compare.svg)

英単語は英字のまま残り、日本語は文の流れに合った変換になります。英語を打つたびに英数キーで英数モードに切り替えたり、変換し直したりしなくて大丈夫です。

## 特徴

### 英語は英語のまま

日本語モードで `ok` と打って「おk」になったことはありませんか？ tugime では、英単語は打ったとおりの英字で残ります。

| 打鍵 | 日本語モードのライブ変換 | tugime |
|---|---|---|
| `ok` | おk | ok |
| `testgaotitanode` | てstが落ちたので | testが落ちたので |

`api` や `name` のようにローマ字としても読める語は、日本語になることがあります（[対処](docs/limitations.md#ローマ字としても読める英単語が日本語になる)）。

### 文の流れに合った変換

tugime は、打った読みをまとめて読む変換モデルで変換します。後ろに続く語まで見て決めるので、「どうきがおそい」は「同期が遅い」に、「ずっとひいている」は「弾いている」になります。

| 打鍵 | 英語を見分けて辞書と統計で変換 | tugime |
|---|---|---|
| `Dropboxnodoukigaosoi.` | Dropboxの動機が遅い。 | Dropboxの同期が遅い。 |
| `CPUnohukagatakai.` | CPUの不可が高い。 | CPUの負荷が高い。 |
| `APInosiyouwosiraberu.` | APIの使用を調べる。 | APIの仕様を調べる。 |
| `pianowo,kodomonokorokarazuttohiiteiru.` | ピアノを、子供の頃からずっと引いている。 | ピアノを、子どもの頃からずっと弾いている。 |

### Space で区切って英文のように打てる

ふつうの日本語入力では、Space は変換のキーです。tugime は打つそばから変換するので、Space はそのまま空白になります。`coming soon` や `pull request` も、日本語モードのまま英文と同じように打てます。英語として残したい語は、空白で区切って打ちます。区切った語は英語に読まれやすくなります。読み方を誤ったときは、続けてもう一度 Space を押すと、その語を英語にするか日本語にするかを候補から選べます。ほかの文節の候補を選びたいときは Shift+Space です。

| 打鍵 | tugime |
|---|---|
| `sonokinouhacoming soondesu.` | その機能はcoming soonです。 |

![同じ文 dark mode の配色を変えて、pull request を出しました。を打つとき、ふつうの日本語入力では文字のほかに英数・かな・変換・Enter を 8 回押す。tugime では Space がそのまま空白になり、文字のほかに押すのは最後の Enter だけ](docs/images/intro.svg)

## 変換の仕組み

![zipwokaitousita. と打つと、tugime は 1 受け取る、2 読み分ける（zip は p が読めないので英語）、3 区切りを決める（zip｜を回答した｜。）、4 変換を仕上げる（zipを解凍した。）の工程で変換する。各工程では InputMethodKit、ローマ字の綴りの表、システム辞書、wordfreq と Webster's、tugime の検査係、genmai-310M、llama.cpp が働く](docs/images/pipeline.svg)

tugime は 1 キー打つたびに、打鍵列の全部をこの 4 つの工程に流し直します。ほかの日本語入力で崩れるのは、この工程の一部が無いためです。

- **日本語モードのライブ変換** には、工程 2 で読めない打鍵を英語にする分かれ道と、工程 3 で日本語と英語の区切り方を比べる処理がありません。日本語だけの文なら文脈に合った漢字を選べますが、英字もすべてローマ字として読むので、英単語が「おk」「てst」になります
- **英語を見分けて辞書と統計で変換する方式** は、工程 3 の仮の漢字で止まります。英単語は英字のまま残りますが、漢字は語の出やすさと隣り合う品詞の組の自然さで選ぶので、「zipを回答した」「動機が遅い」のような組になることがあります

上のデモと表の「日本語モードのライブ変換」は macOS 27 で実際に打った結果、「英語を見分けて辞書と統計で変換」は tugime の比較用の方式（`tugime-cli --method lattice`）の結果です。詳しい仕組みは [変換の仕組み](docs/how-it-works.md) にあります。

## 安全性

入力メソッドは、どのアプリで打った文字も受け取ります。tugime は、偽物を入れないためと、打った内容を外へ出さないために、次のことをしています。

- **導入**: 配布物が tugime のリポジトリで組み立てられたものかを確かめてから入れます。手順は「インストール」にあります
- **通信しない**: tugime は通信しません。さらに macOS の Sandbox で通信とファイルの読み書きを制限し、tugime に穴があって攻撃されたときの被害を減らします
- **記録しない**: 打ち方を学習せず、打った内容を保存しません
- **パスワード欄**: tugime を英字の入力ソースとして登録していません。パスワード欄で入力ソースを英字のものに限るアプリ（Chrome など）では、tugime が選ばれず、変換しません

## 動作環境

Apple Silicon の macOS です。動作は macOS 27 でだけ確かめています。

## インストール

改竄されていない tugime を安全に入れるために、配布物が tugime の release workflow で組み立てられたものかを確かめてから入れます。tugime は Apple の有料の公証を受けていないので、代わりに GitHub 上での署名と[出自の証明](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)を使います。

[Homebrew](https://brew.sh/) で [packslip](https://packslip.dev/) を入れます。

```bash
brew install packslip
```

packslip で tugime を入れます。packslip は確かめられた配布物だけを展開し、`tugime-install` がそれを配置して登録します。更新するときも、このコマンドを実行します。

```bash
packslip install github.com/miyaoka/tugime \
  --identity https://github.com/miyaoka/tugime/.github/workflows/release.yml@refs/heads/main
~/.local/bin/tugime-install
```

[Homebrew 以外のインストール方法（mise、GitHub CLI）](docs/install.md)

### 入力ソースを追加する

初めて入れたときだけ、一度ログアウトしてログインし直してください。システム設定は、ログインし直すまで新しい入力ソースを一覧に出しません。その後、システム設定 → キーボード → 入力ソース → 「+」→ 日本語 から `tugime` を追加します。tugime は自分では入力ソースを有効にしません。

## 使い方

ふだんどおりローマ字で打つだけです。

| キー | 動き |
|---|---|
| 英字・記号 | 打つそばから変換して表示します |
| Space | 空白を入れます。英語として残したい語は空白で区切って打ちます。続けてもう一度押すと、空白の前の語を英語にするか日本語にするかを候補から選べます（`make` → 負け → make） |
| Shift+Space / ↓ | 変換の候補を出します。打っている途中は最初の文節の候補です。候補が出ている間は次の候補へ進みます |
| 1〜9 | 候補が出ている間は、その番号の候補を選び、次の文節に移ります |
| ← / → | 選ぶ文節を左 / 右へ移します。空白だけの文節は飛ばします。打っている途中は、← で最後の文節、→ で最初の文節を選びます |
| Shift+← / Shift+→ | 選んでいる文節を縮める / 伸ばします |
| Enter | 表示しているとおりに確定します |
| Shift+Enter | 選んでいる文節と、その直後の空白までを確定し、残りは変換したまま次の文節を選びます。打っている途中は最初の文節までを確定します |
| 英数 / かな | 英数モード（ABC などの英字の入力ソース）/ tugime に切り替えます |
| Ctrl+H / J / K / L | 未確定の文字列がある間は ← / ↓ / ↑ / → と同じです。ホームポジションのまま文節と候補を選べます |

英語だけの文は、英数モードで打ってください。英語のまま残したい語がかなになるときは、大文字で打つ（`API`）か、tugime の辞書に登録してください。すべてのキー操作と辞書の書き方は [使い方](docs/usage.md) にあります。

## ドキュメント

- [インストール方法](docs/install.md): mise と GitHub CLI でのインストール
- [使い方](docs/usage.md): キー操作、句読点と記号、日本語と英語の見分け方、tugime の辞書
- [変換の仕組み](docs/how-it-works.md): 区切りの決め方と、変換の仕方
- [現状の制限](docs/limitations.md): 誤った変換になる既知の例と対処
- [開発](docs/development.md): ソースからの組み立て、変換の確かめ方、精度の測り方、図の作り直し

## 使っているもの

tugime の変換は、次の辞書とモデルの上に作られています。

- システム辞書: [Mozc](https://github.com/google/mozc) の OSS 辞書・連接の表・文節の規則（BSD 3 条項。辞書は IPAdic と沖縄辞書の利用条件も伴う）
- [genmai-310M](https://huggingface.co/subdiox/genmai-310M)（CC BY-SA 4.0。[zenz-v2.5-medium](https://huggingface.co/Miwa-Keita/zenz-v2.5-medium) を元にしたモデル）と [llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT）
- 既定のローマ字の綴り: [Mozc](https://github.com/google/mozc) の `src/data/preedit/romanji-hiragana.tsv`（BSD 3 条項。ライセンスの全文は `Sources/TugimeCore/Resources/romaji.tsv` の先頭）
- 英語の語の頻度: [wordfreq](https://github.com/rspeer/wordfreq) の日本語データ（CC BY-SA 4.0）
- 英語の綴りらしさを数える語表: macOS 同梱の Webster's Second International（1934 年、著作権切れ）と固有名詞表
- README と docs の図の字形: [LINE Seed JP](https://github.com/line/seed)（SIL Open Font License 1.1）

## ライセンス

tugime は [MIT](LICENSE) です。ただし `Sources/TugimeCore/Resources/` のデータは出典の利用条件に従います。条件はファイルの先頭か `App/Notices/` にあります。
