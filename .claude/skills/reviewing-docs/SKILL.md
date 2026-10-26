---
name: reviewing-docs
description: Use when judging or rewriting human-facing documentation — public docs under priv/docs, a README, a getting-started or how-to page, landing copy — or when someone says docs read robotic, AI-written, dense, jargon-heavy, overwhelming, or "written for a machine". Keywords: doc review, docs quality, readability, Diátaxis, rewrite docs, plain language.
---

# Reviewing docs

## Overview

Judge a page by one question: **would a capable newcomer, reading only this page, know what
it's for, do the thing, and feel spoken to?** Correctness is necessary but it is not the review;
an accurate page can still be unreadable. Be blunt. The usual failure is grading a robotic page
6/10 because its facts check out.

`examples.md` (next to this file) holds praised excerpts and before/after pairs. Read its
good and bad sections before scoring. Its **anchor** section is a scored page: read it only
*after* you've scored, to check you weren't generous — never as an answer key.

## When to Use

Reviewing or rewriting anything a human reader lands on. Not for `relay.md`, skills, agent
prompts, `docs/architecture/`, or ADRs — those are written for agents and maintainers, and
density is fine there. If maintainer pages are *published* on the public docs site, don't score
them; report that as a site-structure finding.

## Process

1. **Name the reader and the page type.** One sentence: who lands here, wanting what. Then the
   [Diátaxis](https://diataxis.fr/) type: *tutorial* (learn by doing), *how-to* (finish a
   task), *reference* (look up a fact), *explanation* (understand why). A page that is two
   types is the finding — say how to split it.
2. **Cold read as the newcomer.** Read only this page. Record: every term you couldn't define
   at first use; the first sentence where you'd stall; how many words you read before you
   could run something and see it work.
3. **Check what the reader will act on against the shipped app.** Prices and plans, install and
   setup commands, and the names of buttons and screens. A cold read can't see staleness, and a
   stale price or a command that fails is worse than bad prose. Grep the app (`lib/`, the landing
   page) and report every mismatch at the top.
4. **Run the counter** for the mechanical tells:
   `python3 -I .claude/skills/reviewing-docs/smells.py priv/docs/<page>.md`
   Smell thresholds on a non-reference page: bold > 1.5 per 100 words, em dashes > 1 per 100,
   > 15% of sentences over 25 words, any ticket ref or `Module.Name` in prose, > 150 words
   before the first runnable command on a tutorial.
5. **Score the rubric** (0 / 1 / 2 each, quote the evidence for every 0):

   | # | Check | 2 looks like |
   |---|---|---|
   | 1 | Opens with the reader's outcome | "You'll have X" / "Do Y to get Z", not what the system is or what the page is |
   | 2 | One page type | Pure; deeper material is a link, not a detour |
   | 3 | A clear default path | "Most people only need…"; options and edge cases moved out of the main line |
   | 4 | Concrete example early | A command or screenshot with what you should see |
   | 5 | Terms defined or absent | Every name explained on first use, or cut |
   | 6 | No implementation leak | No endpoints, flags, file internals, or schema names the reader doesn't act on |
   | 7 | Human voice | "You", active, contractions OK, sounds like a colleague talking |
   | 8 | Sentences carry one idea | No parenthetical-inside-clause-inside-dash stacks |
   | 9 | Formatting earns its place | Bold for the one thing per section you mustn't miss; lists only for real lists |
   | 10 | Success is visible | "You should see…" checkpoints; next step at the end |

   **16–20** reads human · **10–15** needs a pass · **under 10** rewrite it.

   On a **reference** page, read the checks this way. #1: the opening says what you can look up
   here. #3: the most-used entries come first. #4: every entry has an example. #10: you can find
   an entry by scanning. Judge each table cell on its own: a cell that runs to a paragraph fails #8.
6. **Diagnose the cause, not just the symptoms.** In this repo the usual cause is *card
   sediment*: each shipped card appended its edge cases and flags to the page, so the prose
   reads like acceptance criteria. Symptom: a sentence you could delete without the reader
   losing a step. The fix is moving that detail to reference, not polishing it.

## Report

- Score and verdict, the reader sentence, the page type.
- The 3–5 problems that most hurt the reader, worst first. Each one: the quoted sentence, why a
  newcomer trips on it, and a rewrite.
- A rewritten opening (first screen), in the voice the page should have.
- What to cut or move, and where it goes.

For a whole docs site, produce a table: page · type · score · biggest problem. Rank pages in
the order a newcomer *should* read them, not by score. If the sidebar orders them differently,
that's a finding. Then report the overall structure: pages that overlap and should merge, pages
in the wrong section, and pages missing from the path.

## Common mistakes

- **Copyediting a structural problem.** Smoothing sentences on a page that mixes tutorial and
  reference. Split first.
- **Keeping the "for agents" framing.** Public docs are for humans. Agent instructions belong in
  `relay.md` and skills; one pointer line is enough.
- **Fact-checking the wrong things.** Don't audit every claim. Do check step 3's list (prices,
  commands, screen names), because a stale one stops or misleads the reader.
- **Treating counter output as the verdict.** It finds tells; the cold read finds the problem.
- **Scoring generously because nothing is wrong.** "Nothing wrong" isn't "good". Score 2 only
  where the page matches the "2 looks like" column.
- **Rewriting into a different robot.** Bold-colon bullet lists, "not just X but Y", triplets of
  adjectives, and "serves as" are AI tells too. Read your rewrite aloud.
