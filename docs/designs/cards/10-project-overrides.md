# 10 — Per-project flow overrides

**Why.** Requirement 4 of ADR 0006: developers own their process. Repo skills already give
node-behavior ownership for free (agent nodes run in the checkout); this card adds the
structural layer — overriding a node's prompt/model or a flow's shape per project.

**Half-decided (2026-07-16).** Flows are **edited on the board** — versioned rows with a
full editor UI (see the flow-editor card). The remaining question for THIS card: does a
repo file (`.relay/flows.json`) *additionally* layer on top, for customization that
versions with the code and travels with forks? Decide via /brainstorm; "no repo layer,
board only" is now a legitimate answer that would shrink this card to near-zero.

**Scope (once decided).**

- Layered resolution: shipped default ← project override, merged per node; the resolved
  flow is what 02 executes and 07 renders.
- Validation identical to 01 (a broken override fails loudly at load, not mid-run).

**Acceptance criteria.**

1. A project override pointing `implement` at its own repo skill takes effect on the next
   run without any Relay deploy.
2. The card/run UI shows the resolved flow, and shows that an override is in effect.
3. An invalid override is rejected with a clear error; the default keeps working.
4. `mix precommit` passes.
