#!/usr/bin/env python3
"""Count the mechanical "written for a robot" tells in markdown docs.

Usage: python3 -I .claude/skills/reviewing-docs/smells.py FILE [FILE ...]

Prints one block per file. The numbers are tripwires for the reviewing-docs skill,
not a verdict: a reference table full of `code` is fine, a getting-started page is not.
Fenced code blocks and table rows are excluded from prose counts.
"""

import re
import sys

FILLER = [
    "note that", "simply", "just ", "serves as", "it's important", "it is important",
    "this page", "this document", "this section", "not just", "in order to",
    "is written so", "under the hood", "seamless", "robust", "leverage",
]
# Internal identifiers that leak implementation into user prose.
TICKET = re.compile(r"\b(?:RE|RLY|ADR)[- ]?\d{2,}\b")
MODULE = re.compile(r"\b[A-Z][a-z]+(?:\.[A-Z][A-Za-z]+)+(?:/\d)?")
PASSIVE = re.compile(r"\b(?:is|are|was|were|be|been|being)\s+(?:\w+ly\s+)?\w+ed\b", re.I)


def prose_lines(text):
    in_fence = False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence or line.lstrip().startswith("|") or line.lstrip().startswith("<!--"):
            continue
        yield line


def words_before_first_code(text):
    head = text.split("```", 1)[0]
    return len(re.findall(r"\w+", head)) if "```" in text else None


def report(path):
    text = open(path, encoding="utf-8").read()
    lines = list(prose_lines(text))
    prose = " ".join(l.strip() for l in lines if not l.lstrip().startswith("#"))
    words = re.findall(r"[A-Za-z0-9'’]+", prose) or ["x"]
    per100 = lambda n: round(100 * n / len(words), 1)

    sentences = [s for s in re.split(r"(?<=[.!?])\s+", re.sub(r"`[^`]*`", "X", prose)) if s.strip()]
    lens = [len(s.split()) for s in sentences] or [0]
    long = sum(1 for n in lens if n > 25)

    bold_colon = sum(1 for l in lines if re.match(r"\s*[-*\d.]+\s+\*\*[^*]+\*\*\s*[:—–-]", l))
    low = prose.lower()

    print(f"== {path}")
    print(f"  prose words              {len(words)}")
    print(f"  avg sentence length      {sum(lens) / len(lens):.1f} words")
    print(f"  sentences > 25 words     {long}/{len(lens)} ({round(100 * long / len(lens))}%)")
    print(f"  bold spans / 100 words   {per100(len(re.findall(r'\*\*[^*]+\*\*', prose)))}")
    print(f"  em dashes / 100 words    {per100(prose.count('—') + prose.count(' -- '))}")
    print(f"  inline code / 100 words  {per100(len(re.findall(r'`[^`]+`', prose)))}")
    print(f"  bold-colon bullets       {bold_colon}")
    print(f"  passive-ish phrases      {len(PASSIVE.findall(prose))}")
    print(f"  ticket/ADR refs (example data or internal history?) {sorted(set(TICKET.findall(prose)))}")
    print(f"  Module.Names in prose    {sorted(set(MODULE.findall(prose)))[:8]}")
    print(f"  filler phrases           {[f.strip() for f in FILLER if f in low]}")
    print(f"  words before 1st code    {words_before_first_code(text)}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        report(p)
