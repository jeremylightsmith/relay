# MMF 17 — Members & roles
**Milestone:** Post-MVP   **Depends on:** 02
**Design:** BOARD SETTINGS §MEMBERS (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Turns a single-owner board into a shared team workspace — invite people, assign roles, and
recognize the Relay AI as a first-class agent member.

## In scope
- `Membership` (board_id, user_id, role `member|admin`) + invite by email (creates an
  `invited` membership resolved on that user's first sign-in).
- Members pane: people list (initials, name, YOU/INVITED, email, role), send invite,
  change role, remove.
- The **Relay AI agent** appears as an `AGENT` member (non-human), linked to the board's keys.
- Authorization: admins manage settings/keys/members; members use the board.

## Out of scope
- Orgs/workspaces spanning boards — later. Granular per-stage permissions — later.

## Acceptance criteria
- [ ] An admin can invite by email; the invitee gains access on first Google sign-in.
- [ ] The members list shows humans + the Relay AI agent with roles.
- [ ] Role changes gate access to settings/keys/members appropriately.

## Notes
- Assignee/owner avatars across the board draw from memberships (extends MMF 06's rail).
