# MMF 10 — Relay CLI + agent integration docs — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/10-relay-cli.md`](../../mmfs/10-relay-cli.md)
**Status:** Draft for review → `/write-plan`
**Depends on:** MMF 09 (REST API)  ·  **Development:** trunk-based on `main`

## Overview

The payoff: Claude Code pulls a Relay card, works it, and hands it back — from the terminal.
This MMF is **documentation-first**. The main deliverable is a doc that shows both the CLI and
the Claude Code setup (agent / workflow / skill) needed to connect a session to a Relay board.
**Validation is dogfooding:** we follow the doc to wire *this* Claude session to Relay, work a
card live, and update our real `.claude/` setup accordingly. That live hookup is the acceptance
bar — not just a green test.

## Decisions

- **CLI = `mix relay.*` tasks over `Req`** (chosen in brainstorm). No new language/runtime; it
  ships with the repo Claude Code already has and reuses the app's HTTP client + JSON. It talks
  to Relay **only through the MMF 09 REST API** (it is an external client, not a context call),
  configured from env `RELAY_URL` + `RELAY_API_KEY`.
- **Primary artifact = `docs/agent-integration.md`.** It documents the CLI *and* provides
  copy-pasteable example Claude Code constructs — a **simpler** version of the maintainer's
  existing setup — for a session that works Relay cards.
- **`relay pull` default:** returns the next card the agent should work — **AI-owned cards
  first, then unclaimed cards in AI stages** (`stage.owner == :ai`, not done). Documented so we
  can refine it while dogfooding.

## Commands

`mix relay.board` · `relay.card <ref>` · `relay.pull` · `relay.comment <ref> <text>` ·
`relay.move <ref> <stage>` · `relay.status <ref> <status>` · `relay.own <ref>` /
`relay.release <ref>` (claim/hand-back ownership) · `relay.needs_input <ref> <question>`.

- Human-readable output by default; **`--json`** on every command for machine use.
- Clear error messages and **non-zero exit** on failure (bad env, auth, unknown ref, HTTP
  error).

## `docs/agent-integration.md` contents

1. **Setup** — env vars, where to get the board API key (MMF 08 `/board/settings`).
2. **CLI reference** — each command, args, example human + `--json` output.
3. **Claude Code constructs (example, simpler than the maintainer's):**
   - an **agent** definition that works a single Relay card end-to-end,
   - a **workflow** that pulls → works → hands back / requests input,
   - a **skill** that documents the pull-work-handback loop for a session.
4. **Dogfood walkthrough** — the exact steps we follow to connect this session and work a card.

## Testing / validation

- Unit: each `mix relay.*` task builds the right request and renders human + `--json` output;
  errors exit non-zero. (HTTP mocked at the `Req` boundary.)
- **Dogfood (the real acceptance):** with `RELAY_URL`/`RELAY_API_KEY` set against a live board,
  follow `docs/agent-integration.md` to `relay pull` a card and drive it (`comment`, `move`,
  `status`, `own`/`release`, `needs_input`); confirm each reflects on the LiveView board; then
  update our `.claude/` agent/workflow/skill to match the doc.
- `AGENTS.md` links to `docs/agent-integration.md`.

## Acceptance criteria (from the MMF)

- [ ] With env set, `relay board` prints the board's stages + cards.
- [ ] `relay pull` returns the next agent card and it can be worked end-to-end against the live
      board.
- [ ] Every command has `--json`; errors are clear and exit non-zero.
- [ ] `docs/agent-integration.md` documents the CLI + example agent/workflow/skill, and we have
      followed it to connect this session and work a card (dogfood).

## Out of scope

MCP server (MMF 21), auth flows beyond a board key, packaging the CLI as a standalone binary.
