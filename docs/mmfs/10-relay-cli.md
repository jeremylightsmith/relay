# MMF 10 — Relay CLI for Claude Code
**Milestone:** ⭐ MVP   **Depends on:** 09
**Design:** —   **Size:** ~1 loop

## Value
The payoff: Claude Code can pull its assigned card, do the work, and hand it back — all from
the terminal. This is what makes "MMFs become cards Relay runs" real.

## In scope
- A `relay` CLI (thin wrapper over MMF 09) that Claude Code invokes via Bash. Config from env
  (`RELAY_URL`, `RELAY_API_KEY`).
- Commands: `relay board`, `relay card <ref>`, `relay pull` (next AI-owned card),
  `relay comment <ref> <text>`, `relay move <ref> <stage>`, `relay status <ref> <status>`,
  `relay needs-input <ref> <question>`.
- Human-readable output by default, `--json` for machine use.
- Short usage docs so Claude Code (and humans) can self-serve; note it in `AGENTS.md`.

## Out of scope
- MCP server — MMF 21. Auth flows beyond a board key — later.

## Acceptance criteria
- [ ] With `RELAY_URL`/`RELAY_API_KEY` set, `relay board` prints the board's stages + cards.
- [ ] `relay pull` returns the next card in an AI-owned stage and can be worked end-to-end
      (`comment`, `move`, `status`, `needs-input`) against the live board.
- [ ] Every command has `--json`; errors are clear and non-zero-exit.
- [ ] `AGENTS.md` documents how Claude Code uses the CLI to work a card.

## Notes
- Easiest form: a small script (bash+curl or an `escript`/mix task) hitting MMF 09 — no new
  server process. Language is an implementation detail; keep it dependency-light so it runs
  anywhere Claude Code does.
