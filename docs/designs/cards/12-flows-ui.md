# 12 — Flows management UI (board settings tab)

**Why.** W7's cutover ritual needs a humane surface for "enable the Spec flow
server-side" — a toggle with a plain-language warning, not an iex incantation. And once
flows are rows, humans need to *see* them: what's enabled, what's customized, what
triggers where.

**Scope.**

- A **Flows tab** in the existing board settings page (beside Stages / API keys),
  matching the "Relay Flows" artboard: table of flows — name, trigger rendered as
  "Next up → Spec → Spec:Review", isolation badge, version chip, origin badge
  (default / customized), enabled toggle.
- **Enable/disable = the cutover lever**: confirm dialog with the double-dispatch
  warning (legacy watcher must be restarted with the stage removed from
  `relay_config.json` — link the ritual).
- Row actions: Duplicate, Reset to default (confirm; customized flows only). "Edit"
  links to the flow editor (separate card) — render a read-only graph preview until it
  exists.
- First-run state: all flows disabled pre-cutover, with explainer.

**Out of scope.** Editing nodes/edges (flow-editor card), run state (run panel card).

**Acceptance criteria.**

1. `/board/:slug/settings` shows the Flows tab with the three seeded flows, their real
   triggers, versions, and origin badges.
2. Toggling a flow prompts with the cutover warning; confirming flips `enabled` and the
   scheduler honors it within one tick; cancel changes nothing.
3. Reset-to-default on a customized flow restores the shipped definition as a new
   version (history preserved).
4. Matches the "Relay Flows" artboard's elements/states. `mix precommit` passes.
