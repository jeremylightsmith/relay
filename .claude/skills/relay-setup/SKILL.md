---
name: relay-setup
description: Use when wiring a project to a Relay board from scratch — there is no `./relay`, no `.claude/skills/relay-*`, and nothing Relay-shaped installed yet. Downloads the runner from the board, installs the Relay-owned skills, and hands off to `/relay-onboard`. Keywords: relay setup, install relay, set up Relay, new project, bootstrap, board URL, API key, first run.
---

# Relay Setup

## Overview

The entry point, and the **only** thing a fresh project needs. Everything Relay installs is
served by your board — there is no repository to clone and no third-party host in the path.

    /relay-setup = get ./relay → ./relay update (installs the skills) → restart the session
                   → /relay-onboard (wires the repo)

Assume nothing exists. This skill is written to run in a project where the only Relay artifact
is this file.

## When to Use

- A repo that has never talked to a Relay board.
- `./relay` is missing entirely.

Already have `./relay` and the `relay-*` skills, and just want them current? That is
`/relay-update`. Already installed and the flows don't line up with the repo? That is
`/relay-onboard`.

## Step 1 — Establish the board URL and key

`RELAY_URL` is your board host (no trailing slash, no `/board/<slug>` path):

```bash
echo "${RELAY_URL:-<unset>}"
```

If it is unset, **ask the human for their board host** and do not guess. Then:

```bash
export RELAY_URL="https://<board-host>"
```

`RELAY_API_KEY` is a board key. It is **not** needed to install anything below — the scaffold
is served openly — but it is needed the moment the runner runs, so collect it now. Tell the
human: open `$RELAY_URL/board/<slug>/settings` → **API keys** → **+ Create new key**. It is
shown **once**.

```bash
export RELAY_API_KEY="relay_…"
```

Point them at a gitignored `.envrc.local`, their shell profile, or their process manager so
both variables survive a new shell. **Never write a key into a tracked file.**

## Step 2 — Download the runner

```bash
curl -fsSL "$RELAY_URL/api/scaffold/relay" -o relay && chmod +x relay
```

Confirm it: `./relay -h` should print the command groups. If `curl` fails, the board URL is
wrong or the board is unreachable — fix that before continuing; nothing below will work.

## Step 3 — Install the skills

Run the command directly — **do not** invoke `/relay-update` here. That skill is one of the four
files this step installs, so it is not on disk yet and the `Skill` tool cannot resolve a name
that is not installed:

```bash
./relay update --check --json   # what would be written
./relay update --json           # write it
```

Report the `written` list by name. **Expect four, not six** — `./relay update` writes only
what is missing or out of date, and by this point two of the six are already on disk
byte-identical: you curled `./relay` yourself in step 2, and the reader curled
`.claude/skills/relay-setup/SKILL.md` to get this far. Four written is the healthy outcome; do
not treat the other two as a failed install or re-run hunting for them.

`./relay update` is the whole mechanism, and from here on **`/relay-update` owns it** — it
wraps this same command and adds the judgment this skill deliberately skips (where these shared
tooling files get committed). Nothing beyond the one command is re-implemented here.

## Step 4 — Restart the session, then wire the repo to the board

Those four skills were written to disk *during* this session, so Claude Code does not know about
them yet — `/relay-onboard`, `/relay-update` and `/relay-doctor` only become available once the
skill list is rebuilt. Tell the human:

> Relay is installed, uncommitted. **Restart Claude Code** (or start a fresh session), then run
> `/relay-onboard` to wire this repo to your board's flows. These six are shared tooling files —
> `/relay-update` runs the commit conversation with you any time after the restart.

Then stop; setup is done. In that new session `/relay-onboard` reconciles the repo's agents and
skills against the board's flows, loops until `/relay-doctor` reports zero errors, and closes
with the remaining human steps (start `relay start`, enable a flow in Settings › Flows).

## Blast radius

`./relay`, the four `relay-*` skills, and `.relay/scaffold.json`. Never app code, never a
commit, never a push, never a card — `/relay-onboard` does its own work in its own session,
under its own declared radius.
