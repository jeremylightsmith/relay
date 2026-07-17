# 10 — Per-project flow overrides

**Why.** Requirement 4 of ADR 0006: developers own their process. Repo skills already give
node-behavior ownership for free (agent nodes run in the checkout); this card adds the
structural layer — overriding a node's prompt/model or a flow's shape per project.

**Open question to settle first (flagged in the ADR).** Where overrides live:

- **Repo file** (`.relay/flows.json`): versioned with the code, reviewed in PRs,
  travels with forks — but invisible on the board and needs a sync/upload path.
- **Board UI**: visible and editable where runs are watched — but not versioned with the
  code it governs.

Decide via /brainstorm before implementation (a hybrid — repo file as source, board renders
the resolved flow read-only — is a plausible answer).

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
