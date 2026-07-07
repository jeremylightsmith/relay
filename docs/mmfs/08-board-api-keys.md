# MMF 08 — Board API keys
**Milestone:** ⭐ MVP   **Depends on:** 02
**Design:** BOARD SETTINGS §API KEYS (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
A board owner can mint API keys that let external tools (Claude Code) act on the board. This
is the credential that makes the whole integration possible.

## In scope
- `ApiKey` schema (board_id, name, hashed token, prefix/display, created_at, last_used_at,
  created_by).
- Settings → API keys pane: list keys (name, masked display, created/last-used), **Create new
  key** (shows the secret once), **Regenerate**, **Revoke**. Copy-to-clipboard.
- Tokens stored hashed; only a masked display persists after creation.

## Out of scope
- Using the key to authenticate requests — MMF 09. Per-key scopes/permissions — later.

## Acceptance criteria
- [ ] Creating a key shows the full secret exactly once, then only a masked display.
- [ ] Listed keys show name, masked value, created and last-used.
- [ ] Regenerate replaces the secret; Revoke disables the key.
- [ ] Tokens are stored hashed (raw secret never re-retrievable).

## Notes
- Key belongs to a board (matches the design: "these keys authenticate on this board"). Last-
  used is updated by the API layer in MMF 09.
