# MMF 07 — Comments & activity log
**Milestone:** ⭐ MVP   **Depends on:** 04
**Design:** drawer COMMENTS / composer / ACTIVITY (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
A card becomes a conversation and a record. Humans and the AI can post comments, and every
meaningful change is logged — the shared context that survives each handoff.

## In scope
- `Comment` schema (card_id, author = user or agent, body, inserted_at) + composer in the drawer.
- Comments render with author (initials/name), timestamp, optional tag label.
- `Activity` log: system-generated entries for create, move (stage→stage), status change,
  assignment — rendered in the drawer ACTIVITY section.
- Author can be a **human user or the Relay AI agent** (so API-posted comments render correctly).

## Out of scope
- Rich AI result blocks / sub-tasks — MMF 16. @-mentions/notifications — later.

## Acceptance criteria
- [ ] Posting a comment persists it and shows it with author + timestamp.
- [ ] Moving a card or changing its status appends an activity entry automatically.
- [ ] Activity entries and comments are ordered chronologically.
- [ ] A comment authored by the agent renders with the Relay AI identity.

## Notes
- Model `author` polymorphically (user_id XOR agent). This is the surface the API/CLI writes to
  when Claude Code reports progress.
