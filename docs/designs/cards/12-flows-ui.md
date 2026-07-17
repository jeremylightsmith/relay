# 12 — Flows management UI (board settings tab)

**Why.** The spec-flow cutover ritual (RLY-136) needs a humane surface for "enable the Spec flow
server-side" — a toggle with a plain-language warning, not an iex incantation. And once
flows are rows, humans need to *see* them: what's enabled, what's customized, what
triggers where.

**Scope.**

- A **Flows tab** in the existing board settings page (beside Stages / API keys),
  matching `docs/designs/Relay Flows.dc.html`: table of flows — name + node count,
  trigger rendered as "Next up → Spec → Spec:Review", isolation badge (with the legend
  line), version chip, enabled toggle, kebab (Edit / Duplicate / Reset to default —
  the artboard has no origin *column*; the kebab + a "customized" affix carry it).
  Two corrections to the artboard's example data: triggers pull from **Done**
  substages (its "Spec:Review → Plan" would race the approve gate), and its stage
  names ("In progress", Deploy flow) are exemplary — real rows come from the board.
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
2. Toggling a flow prompts with the cutover warning; confirming persists `enabled`
   (and, once the scheduler exists — RLY-133 — it honors the flag within one tick);
   cancel changes nothing. Pre-scheduler, the tab shows a quiet "engine not running
   yet" note so the toggle doesn't overpromise.
3. Reset-to-default on a customized flow restores the shipped definition as a new
   version (history preserved).
4. Matches the "Relay Flows" artboard's elements/states. `mix precommit` passes.
