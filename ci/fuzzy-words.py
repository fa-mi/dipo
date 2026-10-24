#!/usr/bin/env python3
"""Common words that sit a slip away from a word DiPo knows.

FuzzyName (DiPo/FuzzyName.swift) reads "indimaret" as a slip of Indomaret.
Without a dictionary it would read real words the same way: "pertama" (first)
as Pertamax, "renang" (swimming) as rendang, "keuangan" as Kopi Kenangan's
second word. This prints the common Indonesian and English words that sit
within FuzzyName's allowance of a word in SmartBudgetManager.merchantMap or
LocalTxParser.categoryWords, as the Swift set FuzzyName.commonWords.

Run by hand after adding a keyword to either list, and paste the output over
FuzzyName.commonWords:

    pip install wordfreq
    python3 ci/fuzzy-words.py

The rules mirror FuzzyName.allowance and FuzzyName.isTypo; keep them in step.
"""
import pathlib
import re

from wordfreq import top_n_list, zipf_frequency

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Once per million words or more, in either language.
FLOOR = 3.0
LIST_SIZE = 200_000


def quoted(path, start):
    source = (ROOT / path).read_text()
    begin = source.index(start)
    end = source.index("\n    ]\n", begin)
    return re.findall(r'"([^"]*)"', source[begin:end])


def allowance(n):
    return 0 if n < 6 else (1 if n < 11 else 2)


def distance(a, b, limit):
    """Optimal string alignment, as FuzzyName.distance."""
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    before, previous = [0] * (len(b) + 1), list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        current = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cost = min(previous[j] + 1, current[j - 1] + 1,
                       previous[j - 1] + (a[i - 1] != b[j - 1]))
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                cost = min(cost, before[j - 2] + 1)
            current[j] = cost
        before, previous = previous, current
    return previous[len(b)]


def is_typo(typed, known):
    if typed == known or len(typed) < 6 or typed[0] != known[0]:
        return False
    allowed = allowance(len(known))
    return allowed > 0 and distance(typed, known, allowed) <= allowed


keywords = (quoted("SmartBudgetManager.swift", "static let merchantMap")
            + quoted("LocalTxParser.swift", "static let categoryWords"))
known = {word for keyword in keywords for word in keyword.split()}
targets = {word for word in known if len(word) >= 6 and word.isalpha()}

common = set()
for language in ("id", "en"):
    for word in top_n_list(language, LIST_SIZE):
        if len(word) < 6 or not (word.isascii() and word.isalpha()) or word in known:
            continue
        if max(zipf_frequency(word, "id"), zipf_frequency(word, "en")) < FLOOR:
            continue
        # A longer form ("flights") already matches as written.
        if any(is_typo(word, target) and target not in word for target in targets):
            common.add(word)

lines, line = [], ""
for word in sorted(common):
    piece = f'"{word}", '
    if len(line) + len(piece) > 84:
        lines.append(line.rstrip())
        line = ""
    line += piece
lines.append(line.rstrip().rstrip(","))
print("    static let commonWords: Set<String> = [")
for text in lines:
    print("        " + text)
print("    ]")
