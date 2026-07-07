# MMF 21 — MCP server (alternative to the CLI)
**Milestone:** Optional   **Depends on:** 09
**Design:** —   **Size:** ~1 loop

## Value
Gives Claude Code (and other MCP clients) native, structured tools for Relay — `pull_card`,
`comment`, `move_card`, `set_status`, `needs_input` — a more ergonomic integration than
shelling out to the CLI, without a new logic path.

## In scope
- An MCP server exposing Relay's board actions as tools, backed by the same REST API (MMF 09)
  and a board key.
- Tool set mirroring the CLI (MMF 10): read board/card, pull next AI card, comment, move,
  set status, raise needs-input.
- Setup docs for registering it with Claude Code.

## Out of scope
- Replacing the CLI — both can coexist; the CLI remains the zero-dependency baseline.

## Acceptance criteria
- [ ] The MCP server authenticates with a board key and exposes the tool set.
- [ ] Claude Code can complete a card end-to-end via MCP tools against a live board.
- [ ] Docs cover registration and configuration.

## Notes
- Only build if the CLI proves too clunky in practice — decide after dogfooding MMF 10.
