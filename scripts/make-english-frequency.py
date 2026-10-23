# 日本語の文章に英字のまま書かれる語と、その出現頻度（Zipf 値）の表を作る。
# 英語の語ではない綴りとして english-frequency-excluded.txt に挙げた語を外す。
# 使い方: python3 -m venv <dir> && <dir>/bin/pip install wordfreq==3.1.1
#         <dir>/bin/python -I scripts/make-english-frequency.py Sources/TugimeCore/Resources/english-frequency.tsv
import math
import pathlib
import sys

from wordfreq import get_frequency_dict

excluded_path = pathlib.Path(__file__).with_name("english-frequency-excluded.txt")
excluded = {
    line for line in excluded_path.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")
}

frequencies = {}
for word, frequency in get_frequency_dict("ja").items():
    if not (word.isascii() and word.isalpha()):
        continue
    key = word.lower()
    frequencies[key] = frequencies.get(key, 0.0) + frequency

# 除外する語が wordfreq に無ければ、綴りの誤りか元データの変化なので止める
missing = sorted(excluded - frequencies.keys())
if missing:
    sys.exit(f"除外する語が元データに無い: {' '.join(missing)}")
for word in excluded:
    del frequencies[word]

with open(sys.argv[1], "w") as out:
    for word in sorted(frequencies):
        out.write(f"{word}\t{math.log10(frequencies[word] * 1e9):.2f}\n")
