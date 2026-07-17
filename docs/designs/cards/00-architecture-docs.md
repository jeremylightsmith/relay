# 00 — Living architecture docs: `docs/architecture/` + freshness gates

**Why.** The docs answer *why we decided* (ADRs), *what it should look like* (designs),
*what words mean* (glossary), and *where we're going* (vision) — nothing answers **"what is
the system, today?"** Written against the codebase as it exists now, so the ADR 0006 work
lands into a documentation structure that's already standing and already enforced.

**Scope.**

- `docs/architecture/` with five pages, each hand-written ones capped at ~1–2 pages, each
  ending in a "sources of truth" footer naming the modules it describes:
  - `README.md` — one-page system map (Phoenix on Fly, Postgres, executor on dev machines,
    mobile shell, Google auth) with one Mermaid container diagram; links out to ADRs,
    glossary, designs, agent-integration.
  - `domain.md` — one short entry per context (`Boards`, `Cards`, `Activity`, `Accounts`,
    `Members`, `ApiKeys`, `Attachments`, `Push`, `AgentLog`, `Events`, …): purpose, key
    schemas, invariants *as links to the governing ADR* (never restated); one Mermaid ER
    diagram of the core schemas.
  - `runtime.md` — supervision tree, a **table of every PubSub topic**, and Mermaid
    sequence diagrams for the load-bearing flows (card move fan-out; needs-input round
    trip).
  - `runner.md` — how work physically gets done: today's `bin/relay watch` (pools,
    worktree salvage, streaming, flag/needs-input behavior). ADR 0006's sketches migrate
    here as they become real.
  - `deps.md` — the boundary module graph plus a hand-maintained table of load-bearing
    external deps and services (why we have each).
- Freshness gates:
  - `AGENTS.md` rule: adding a context, PubSub topic, API endpoint, or supervised process
    requires updating the matching `docs/architecture/` page in the same branch.
  - One checklist line in the `final-reviewer` agent: does this branch change architecture
    that `docs/architecture/` describes, and is the page updated?

**Out of scope (follow-up card if wanted).** A `mix arch.gen` task that regenerates the
boundary graph / ER diagram with a precommit staleness check, `mix format`-style. Start
with hand-drawn Mermaid; automate when drift is actually observed.

**Acceptance criteria.**

1. All five pages exist, within budget, with sources-of-truth footers; every Mermaid
   diagram renders on GitHub.
2. `runtime.md`'s PubSub table matches a grep for actual topic strings; `domain.md`'s
   context list matches `Relay`'s boundary `exports`.
3. `AGENTS.md` and the `final-reviewer` agent contain the freshness-gate lines.
4. `mix precommit` passes.
