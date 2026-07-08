# Working Relay from Claude Code

Relay is programmable over a small REST API (MMF 09) and a `mix relay` CLI (MMF 10). This guide
shows how a Claude Code session pulls a card, works it, and hands it back — the "passing the
baton" loop, driven from the terminal.

> **Scope:** this documents the CLI and gives *example* Claude Code constructs. Wiring your own
> `.claude/` setup is a copy-and-adapt step — this repo does not ship those as live config.

## Setup

1. Mint a board API key: open `/board/settings` in Relay → **Generate key** → copy the
   `relay_…` secret (shown once).
2. Export the two env vars Claude Code's shell will use:

   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```

## CLI reference

Every command prints human-readable text by default; add `--json` for machine output. Non-zero
exit on any error (bad env, auth, unknown ref, HTTP error).

| Command | What it does |
|---|---|
| `mix relay board` | The board: stages with their cards |
| `mix relay card RLY-12` | One card with description + timeline |
| `mix relay pull` | The next card to work: AI-owned first, else an unclaimed card in an AI stage |
| `mix relay comment RLY-12 "on it"` | Post a comment (as Relay AI) |
| `mix relay move RLY-12 Code` | Move the card to a stage (by name) |
| `mix relay status RLY-12 working` | Set status (`queued`/`working`/`needs_input`/`in_review`/`done`) |
| `mix relay needs-input RLY-12 "Which region?"` | Flag needs_input + record the question |
| `mix relay own RLY-12` | Claim the card for the AI |
| `mix relay release RLY-12` | Clear owners (hand back) |

## The baton loop

```bash
ref=$(mix relay pull --json | jq -r '.ref')   # find the next AI card
mix relay own "$ref"                            # take the baton
mix relay status "$ref" working                 # ...work it...
mix relay comment "$ref" "Implemented X, tests green"
mix relay move "$ref" Review                     # hand to a human stage
mix relay release "$ref"
```

## Example Claude Code setup (copy & adapt)

A **skill** that documents the loop for a session — `.claude/skills/work-relay-card/SKILL.md`:

```markdown
---
description: Pull a Relay card, do the work, hand it back via the mix relay CLI.
---

1. `mix relay pull` to get your card (its ref + description).
2. `mix relay own <ref>` and `mix relay status <ref> working`.
3. Do the work in the repo (TDD).
4. `mix relay comment <ref> "<what you did>"`; if blocked, `mix relay needs-input <ref> "<question>"`.
5. `mix relay move <ref> Review` and `mix relay release <ref>` when done.
```

An **agent** that works a single card — `.claude/agents/relay-worker.md`:

```markdown
---
name: relay-worker
description: Works one Relay card end-to-end from pull to hand-back.
tools: [Bash, Read, Edit, Write]
---

You work exactly one Relay card. Use the `work-relay-card` skill's loop. Never touch a card that
isn't the one you pulled. Report the final ref + status as your result.
```

A **workflow** (sketch) that pulls and fans out one worker per available card:

```js
// .claude/workflows/work-relay-board.js — sketch
const refs = JSON.parse(await sh("mix relay pull --json")) // extend to list multiple
await parallel(refs.map(r => () => agent(`Work Relay card ${r.ref}`, { agentType: "relay-worker" })))
```

## Dogfood

To validate: point the env vars at a real board, run `mix relay pull`, work the card, and hand
it back — then adapt the examples above into your own `.claude/` setup.
