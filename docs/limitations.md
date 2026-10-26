# 現状の制限

誤った表示になる既知の例と、利用者ができる対処。表示は `tugime-cli --live <打鍵列>` で再現できる。対応する issue が閉じたら、その項を消す。

## ローマ字としても読める英単語が日本語になる

| 打鍵列 | 表示 | 期待 |
|---|---|---|
| `homenomenuwokaeru` | homeのメヌを飼える | homeのmenuを変える |
| `modenokirikaewotuikasuru` | モデの切り替えを追加する | modeの切り替えを追加する |
| `asitanomeetingmadeniapinosiyouwosiraberu` | 明日のmeetingまでにアピの仕様を調べる | 明日のmeetingまでにapiの仕様を調べる |

対処: 大文字で打つ（`API`）、tugime の辞書に `en` で登録する、F10 で打ったままに戻す。issue: [#21](https://github.com/miyaoka/tugime/issues/21)

## 日本語の読みの途中が英語の語に割れる

| 打鍵列 | 表示 | 期待 |
|---|---|---|
| `diskniyouryougatarinai` | diskにyour用が足りない | diskに容量が足りない |

対処: Shift+Space で文節を選び、文節を伸縮して変換し直す。issue: [#61](https://github.com/miyaoka/tugime/issues/61)

## 前の文の誤りに引っ張られる

入力欄のカーソルより前の文字列を変換の文脈にするので、前に誤った文があると、それに合わせて誤ることがある。前に「ピアノを、子供の頃からずっと引いている。」があると、`pianowo,kodomonokorokarazuttohiiteiru.` が「引いている」になる。

対処: 前の文を直してから打つ。issue: [#60](https://github.com/miyaoka/tugime/issues/60)

## 英語の後ろの語は、英語より前の変換の手がかりにならない

日本語の区間は前から順に、左の文脈だけを見て変換する。英語の区間で分かれた後ろの日本語は、前の日本語の漢字を選ぶ手がかりにならない。

対処: Shift+Space で文節を選び、候補から選び直す。
