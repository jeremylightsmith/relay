# MMF 20 — Landing page
**Milestone:** Post-MVP   **Depends on:** —
**Design:** `Relay Landing.dc.html` (full)   **Size:** ~1 loop

## Value
The public front door that explains Relay to newcomers and routes them to sign in — the story
of "pass work between people and AI without losing the thread."

## In scope
- Public marketing page from the mockup: nav, hero + hero board visual, "how it works" (3
  cards), the blocked/asks-a-question feature, the flow strip, configurable-stages section,
  CTA, footer.
- "Open the board" / "Sign in" route to Google login (MMF 01).
- Responsive; built with the design tokens (Tailwind 4 + daisyUI 5).

## Out of scope
- CMS/marketing analytics — later. Pricing/docs pages — later.

## Acceptance criteria
- [ ] `/` (logged out) renders the landing page matching the mockup's sections.
- [ ] CTAs route to sign-in; signed-in users go to their board.
- [ ] Page is responsive and passes the design's look in light/dark.

## Notes
- Lowest priority for the dogfood MVP; high value once Relay is shown to others.
