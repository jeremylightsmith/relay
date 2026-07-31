# Relay documentation — the map

Relay's prose lives in **nine homes**. Each home has one reader, one kind of content, and one
lifecycle. The rule is **one fact, one home; everywhere else links** — the *why* behind that, and
the full rationale for each row below, is
[ADR 0008 — Documentation taxonomy](adr/0008-documentation-taxonomy.md). This page is only the
map: where to look, and where to put something new.

## The nine homes

| Home | Who it's for | What belongs there | Lifecycle | Published |
| --- | --- | --- | --- | --- |
| [`relay.md`](../relay.md) | a driver agent in **another repo's** context | how to drive a card with `bin/relay` | current; tiny; shipped out by `bin/relay init` | in every consuming repo |
| `priv/docs/` | an integrator or operator **browsing a URL** | product + integration reference and onboarding | current | **public site** (`/docs`) |
| [`docs/architecture/`](architecture/README.md) | a **contributor editing this repo** | how the system works **today** | current; freshness-gated | **public site** (symlinked) |
| [`docs/adr/`](adr/README.md) | anyone weighing or reviewing a **structural change** | a decision and its rationale — the *why* | durable; immutable once Accepted | internal |
| [`docs/glossary.md`](glossary.md) | anyone — the **tiebreaker** | vocabulary bound to code | current | internal |
| [`docs/vision.md`](vision.md) | product / anyone | the north-star narrative | aspirational | internal |
| [`docs/designs/`](designs/README.md) | a **UI builder** | hi-fi mockups — the visual source of truth | current; re-pulled from Claude Design | internal |
| `docs/runbooks/` | an **operator** | a step-by-step procedure with a rollback | current | **public site** (symlinked) |
| [`AGENTS.md`](../AGENTS.md) + `.claude/skills/` | the **in-repo agent** | standing rules; executable process | current | internal |

## Published vs internal

Published means served on the `/docs` site. Of the `docs/` tree,
only `docs/architecture/` and `docs/runbooks/` are published. They reach the site through the
committed symlinks `priv/docs/architecture -> ../../docs/architecture` and
`priv/docs/runbooks -> ../../docs/runbooks`, so they stay the single source of truth — there is no
copy step. A page is served once it is registered in `RelayWeb.DocsController`'s `@pages_meta`.

Anything published is dual-audience — a contributor *and* an outside site reader — and must read
acceptably to someone who has never seen the repo. `docs/adr/`, `docs/glossary.md`,
`docs/vision.md`, `docs/designs/` and this file are **repo-internal by decision**: they assume
repo context and are deliberately not on the site.

## Where does this go? — the placement test

Ask, in order:

1. Is it *"why we chose X over Y"*? → an **ADR**. If it also describes how the system works today,
   that half is not ADR material — split it into `docs/architecture/` and link.
2. Is it a **term** everyone must use consistently? → the **glossary** (others link, never redefine).
3. Does it describe **how the system works right now**, such that a code change could falsify it?
   → **`docs/architecture/`**, updated in the same branch as the change.
4. Is it *"how do I, from outside, do X with Relay"*? → the hosted **`/docs` site** if the reader is
   browsing; **`relay.md`** if it is context shipped into a driver agent.
5. Is it an **operational ritual** with steps and a rollback? → a **runbook**.
6. Is it what we are **aiming at**, not what exists? → **vision**.
7. Is it a **rule the in-repo agent** must follow while working? → **`AGENTS.md`** (a standing
   rule) or **a skill** (an executable procedure).

Then the duplication check: if the fact already has a home, this instance **links** to it — unless
it is a user-facing `/docs` concept page, which may restate it simply but must not drift from the
canonical source. Values of a closed set are the one restatement that is machine-checked: tag the
table with a `vocab:` HTML comment naming the accessor that owns the set, and
`test/relay/docs_vocabulary_test.exs` holds the table to that function's values. See
`priv/docs/cards-and-handoffs.md` for the exact marker syntax.

## Named sources of truth

| Fact | Home |
| --- | --- |
| Vocabulary / term definitions | [`glossary.md`](glossary.md) |
| The closed vocabularies, the four state machines and their transitions | [`architecture/state.md`](architecture/state.md) (generated) |
| Every known failure mode and how it is handled | [`architecture/failures.md`](architecture/failures.md) |
| REST endpoints | `priv/docs/api.md` |
| CLI commands | `priv/docs/cli.md` |
| PubSub topics and supervised processes | [`architecture/runtime.md`](architecture/runtime.md) |
| "What Relay is" / the north star | [`vision.md`](vision.md) |
| How work physically runs (dispatch, executor, worktrees) | [`architecture/runner.md`](architecture/runner.md) |
