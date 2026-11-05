"""Teach Kokoro the guides' frontier words (stdlib only; runs in CI and scripts/install-iphone.sh).

Words like "ridin'" and "'bout" aren't in the lexicon, so espeak guesses them letter by letter, which sounds robotic.
This derives them from the full word ("riding" with its final "ng" said as "n") for every such word in the guide
lines, and appends them. Safe to run again: words already present are skipped.
Usage: python3 dialect_lexicon.py Kokoro/lexicon-us-en.txt Sources/Guide.swift
"""
import re
import sys


def main(lexicon, source):
    lex = {}
    with open(lexicon, encoding="utf-8") as f:
        for line in f:
            word, *phones = line.split()
            lex.setdefault(word.lower(), phones)
    with open(source, encoding="utf-8") as f:
        words = {w.lower() for w in re.findall(r"[A-Za-z]*'?[A-Za-z]+'?", f.read())}
    added = {}
    for w in sorted(words - lex.keys()):
        if w.endswith("in'") and w[:-1] + "g" in lex and lex[w[:-1] + "g"][-1] == "ŋ":
            added[w] = lex[w[:-1] + "g"][:-1] + ["n"]
        elif w.startswith("'") and "a" + w[1:] in lex:  # 'bout -> about, minus the first vowel
            added[w] = lex["a" + w[1:]][1:]
    with open(lexicon, "a", encoding="utf-8") as f:
        for w, phones in added.items():
            f.write(f"{w} {' '.join(phones)}\n")
    print(f"dialect words added: {', '.join(added) or 'none'}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
