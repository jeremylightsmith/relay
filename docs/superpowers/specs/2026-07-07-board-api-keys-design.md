# MMF 08 — Board API key — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/08-board-api-keys.md`](../../mmfs/08-board-api-keys.md)
**Status:** Draft for review → `/write-plan`
**Depends on:** MMF 02 (board), 06 (`Schemas` boundary)
**Development:** trunk-based on `main`

## Overview

A board owner mints an API key so external tools (Claude Code, via MMF 09/10) can act on the
board. **One key per board for now** (may become many later — the schema already allows it).

## Decisions

- **Single active key per board.** Not a list — the settings pane manages exactly one key. The
  `api_keys` table keeps `board_id` so expanding to multiple later is a constraint change, not a
  reshape.
- **New `Relay.ApiKeys` context** + `Schemas.ApiKey`. Tokens are stored **hashed**; the raw
  secret is shown exactly **once** at creation.
- **Token format `relay_<prefix>_<secret>`.** `prefix` is a short random public id stored in
  the clear (for lookup + masked display); `secret` is hashed with **SHA-256** (fast, correct
  for high-entropy API tokens — bcrypt is for passwords). Auth (MMF 09) looks up by prefix then
  constant-time compares the hash.
- **New `/board/settings` LiveView** hosts the keys pane. This is the first settings surface;
  MMF 12 (stage config) and MMF 10b (sub-lane toggles) extend the same page, MMF 19 generalises
  it.

## Data model

**`Schemas.ApiKey`**: `board_id`, `name` :string, `token_prefix` :string (unique),
`token_hash` :string, `last_four`/masked-display :string, `created_by_id` (user),
`last_used_at` :utc_datetime (nullable), timestamps. At most one row per `board_id`.

`Relay.ApiKeys`: `create_key/2` (returns `{key, raw_token}` — raw only here), `get_key/1`,
`regenerate/1` (new secret, same row), `revoke/1` (delete/disable),
`authenticate(raw_token)` → `{:ok, board}` | `:error` (used by MMF 09; bumps `last_used_at`).

## Behaviour / UI (`/board/settings` → API key pane)

- **No key yet:** a "Generate key" button → creates the key and reveals the full
  `relay_…` secret once with copy-to-clipboard, plus a "copy it now, you won't see it again"
  note.
- **Key exists:** shows `name`, masked value, created + last-used, with **Regenerate**
  (reveals a new secret once, invalidates the old) and **Revoke** (removes the key).
- Only the board owner can view/manage keys (current-scope authorization).

## Testing

- Generating a key shows the full secret exactly once, then only a masked display on reload.
- The pane shows name, masked value, created, and last-used.
- Regenerate replaces the secret (old raw no longer authenticates); Revoke removes the key.
- Tokens are stored hashed — the raw secret is never re-retrievable from the DB.
- A second "generate" while a key exists is not offered (single-key invariant holds).

## Acceptance criteria (from the MMF)

- [ ] Creating a key shows the full secret exactly once, then only a masked display.
- [ ] The key shows name, masked value, created and last-used.
- [ ] Regenerate replaces the secret; Revoke disables/removes the key.
- [ ] Tokens are stored hashed (raw secret never re-retrievable).

## Out of scope

Authenticating requests with the key (MMF 09), multiple keys per board, per-key
scopes/permissions.
