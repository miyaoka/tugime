# 日本語の文章に英字のまま書かれる語と、その出現頻度（Zipf 値）の表を作る。
# 使い方: python3 -m venv <dir> && <dir>/bin/pip install wordfreq==3.1.1
#         <dir>/bin/python -I scripts/make-english-frequency.py Sources/TugimeCore/Resources/english-frequency.tsv
import math
import sys

from wordfreq import get_frequency_dict

frequencies = {}
for word, frequency in get_frequency_dict("ja").items():
    if not (word.isascii() and word.isalpha()):
        continue
    key = word.lower()
    frequencies[key] = frequencies.get(key, 0.0) + frequency

with open(sys.argv[1], "w") as out:
    for word in sorted(frequencies):
        out.write(f"{word}\t{math.log10(frequencies[word] * 1e9):.2f}\n")
