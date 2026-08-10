---
name: relay-setup
description: Use when wiring a project to a Relay board from scratch — there is no `bin/relay`, no `.claude/skills/relay-*`, and nothing Relay-shaped installed yet. Downloads the executor from the board, installs the Relay-owned skills, and hands off to `/relay-onboard`. Keywords: relay setup, install relay, set up Relay, new project, bootstrap, board URL, API key, first run.
---

# Relay Setup

## Overview

The entry point, and the **only** thing a fresh project needs. Everything Relay installs is
served by your board — there is no repository to clone and no third-party host in the path.

    /relay-setup = get bin/relay → /relay-update (installs the skills) → /relay-onboard (wires the repo)

Assume nothing exists. This skill is written to run in a project where the only Relay artifact
is this file.

## When to Use

- A repo that has never talked to a Relay board.
- `bin/relay` is missing entirely.

Already have `bin/relay` and the `relay-*` skills, and just want them current? That is
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
is served openly — but it is needed the moment the executor runs, so collect it now. Tell the
human: open `$RELAY_URL/board/<slug>/settings` → **API keys** → **+ Create new key**. It is
shown **once**.

```bash
export RELAY_API_KEY="relay_…"
```

Point them at a gitignored `.envrc.local`, their shell profile, or their process manager so
both variables survive a new shell. **Never write a key into a tracked file.**

## Step 2 — Download the executor

```bash
mkdir -p bin
curl -fsSL "$RELAY_URL/api/scaffold/bin/relay" -o bin/relay && chmod +x bin/relay
```

Confirm it: `bin/relay --help` should print the verb list. If `curl` fails, the board URL is
wrong or the board is unreachable — fix that before continuing; nothing below will work.

## Step 3 — Install the skills

Invoke **`/relay-update`** (via the `Skill` tool). It pulls the four `relay-*` skills, keeps
`bin/relay` current, and handles the commit conversation. Do not re-implement any of that here.

## Step 4 — Wire the repo to the board

Invoke **`/relay-onboard`** (via the `Skill` tool). It reconciles the repo's agents and skills
against the board's flows and loops until `/relay-doctor` reports zero errors.

That is the end of setup. `/relay-onboard` closes with the remaining human steps (start
`relay execute`, enable a flow in Settings › Flows).

## Blast radius

`bin/relay`, the four `relay-*` skills, and whatever `/relay-onboard` does within its own
declared radius. Never app code, never a push, never a card.
