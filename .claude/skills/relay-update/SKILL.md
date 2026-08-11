---
name: relay-update
description: Use when a project's Relay tooling may be stale — refreshing `bin/relay` and the `relay-*` skills from the board, after a Relay release, or when a run was refused with `executor_outdated`. Keywords: relay update, update bin/relay, refresh skills, scaffold, executor outdated, stale tooling.
---

# Relay Update

## Overview

Relay owns exactly five files in your project:

| Item | Path |
|---|---|
| the executor | `bin/relay` |
| entry-point skill | `.claude/skills/relay-setup/SKILL.md` |
| updater skill | `.claude/skills/relay-update/SKILL.md` |
| doctor skill | `.claude/skills/relay-doctor/SKILL.md` |
| onboarding skill | `.claude/skills/relay-onboard/SKILL.md` |

Your board serves them at `$RELAY_URL/api/scaffold`. They are **never user-edited**, so an
update overwrites them unconditionally — there is nothing of yours to lose, and no diff to
review. Everything else in `.claude/` is yours and this skill never touches it.

`bin/relay update` owns the mechanism. This skill owns the judgment: whether to update, and
what to do with the resulting diff. **No update policy lives in this prose** — if you want to
know what would change, ask the command.

## When to Use

- A Relay release shipped and this project has not picked it up.
- A run was refused with `executor_outdated`, or the Runners view shows an `OUTDATED` badge.
- One of the five files above is missing, was deleted, or was edited — `update` repairs all
  three the same way, because none of them is yours to change.

**Never run this in the Relay app repo itself.** There these five files are the *source*, not
installed copies, and because publishing is coupled to deploying (ADR 0010) the board serves
whatever was last deployed — so an update reverts local work to it. `bin/relay update` refuses
there without `--force`; `--check` is still fine and still tells you the truth.
- Any time someone asks "is our Relay tooling current?"

## The checklist

Do these in order. Do not skip step 3.

### 1. Check the version

```bash
bin/relay update --check --json
```

Read `current`. If it is `true`, say so — name the version — and **stop**. There is nothing to
do and no commit to discuss.

If it is `false`, report the `changed` list by name before you write anything.

### 2. Pull the files

```bash
bin/relay update --json
```

Report `written` by name. If `bin/relay` is in that list, mention that a running
`relay execute` keeps serving the old code until it restarts (it will pick this up itself at a
job boundary if `auto_update` is on).

### 3. Confirm the commit, and explain why it matters

These are **shared tooling** files. Ask the human where to commit them, and give the reason —
do not just ask:

> I'd prefer to commit these to `main`. They're shared tooling: left on a feature branch, every
> other worktree and every executor on this repo keeps running the stale copies, and the change
> gets tangled into an unrelated PR's diff. Commit to `main`?

Then **accept their answer.** Current branch, a different branch, or no commit at all are all
fine — say what you're doing and do that.

### 4. Do it

- Stage **only the files this run wrote** — the `written` list from step 2, one `git add` per
  path. **Never `git add -A`.**
- Commit with a message naming the version, e.g.
  `chore(relay): update scaffold to a3f9c81b20d4`.
- **Never push.** Pushing is the human's call and is not part of this skill.

## Blast radius

The five files above, `.relay/scaffold.json`, and one commit if the human asked for one. Never
app code, never other `.claude/` files, never a branch, never a push, never a card.
