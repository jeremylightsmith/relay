# MMF 14 — "Needs input" question ↔ answer
**Milestone:** Post-MVP   **Depends on:** 06, 07
**Design:** card NEEDS INPUT, drawer "RELAY AI NEEDS YOUR INPUT" + answer composer (`Relay Board.dc.html`, Landing §blocked)   **Size:** ~1 loop

## Value
The behavior that makes Relay trustworthy: when the AI is unsure it **asks instead of
guessing**, the card blocks visibly, and the human answers inline — then the AI resumes.

## In scope
- A card in `needs_input` carries a `question`; board shows the amber treatment, drawer shows
  the question panel with an answer composer ("Send to AI →").
- Submitting an answer records it (as a comment/activity), clears the block, and returns the
  card to `working`/queued for its AI stage.
- The API side (`POST /needs-input`, and reading the answer) is MMF 09; this MMF is the human
  UX + state round-trip.

## Out of scope
- Actually running an AI to consume the answer — that's the external agent (Claude Code) via CLI.

## Acceptance criteria
- [ ] An agent (or user) can put a card into `needs_input` with a question; the board flags it.
- [ ] The drawer shows the question and an answer composer.
- [ ] Submitting an answer logs it and transitions the card out of `needs_input`.
- [ ] The answer is retrievable via the API so the agent can continue.

## Notes
- "Waiting on a human, and for how long" (design) implies tracking `blocked_since` for later
  aging/metrics.
