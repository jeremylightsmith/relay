# ADR 0008 — Documentation taxonomy: what lives where, and why

## Status
Proposed (2026-07-30)

## Context

Relay's prose documentation is spread across **nine homes** — `relay.md`, the hosted `/docs`
site (`priv/docs/*`), `docs/architecture/*`, `docs/adr/*`, `docs/glossary.md`, `docs/vision.md`,
`docs/designs/*`, `docs/runbooks/*`, and the in-repo agent instructions (`AGENTS.md` +
`.claude/skills/*`). Each grew for a real reason and serves a genuinely different reader, but the
boundaries between them were never written down. The costs are now visible:

- **No map.** There is no `docs/README.md` or index; discovery is hub-and-spoke from `AGENTS.md`.
  Which `docs/*` dirs are also published on the public site (`architecture` and `runbooks`, via
  committed symlinks) versus repo-internal (adr, vision, glossary, designs) is implicit.
- **The same fact lives in several homes and drifts.** The run-state machine is written three
  times (generated `state.md`, prose in `domain.md`, a hand-drawn copy in ADR 0007 that no check
  guards). "What Relay is" is written three times (`vision.md`, root `README.md`,
  `introduction.md`). Card status is stated as *four* values on one site page and *five* on
  another.
- **Category confusion.** ADR 0007 is half current-state failure-map (reference) and half
  decision + tracked gaps; it doesn't satisfy a single category. ADRs 0006/0007 have sprawled
  toward design docs. Status-header formatting varies, and ADR 0003 was amended in place —
  against this directory's own immutability rule.

This mirrors a rule we already enforce in code — *"a magic value is defined exactly once"*
(`AGENTS.md`). We lack the equivalent for prose. This ADR writes down the homes, who each is
for, and a test for whether a given piece of documentation is in the right one.

## Decision

### Principle: one fact, one home; everywhere else links

Every documented fact has exactly **one** canonical home. Other docs that need it **link**
rather than restate it. When a fact is found in two homes, one is canonical and the other must
become a link. This is the prose form of the "defined exactly once" rule.

**The one carve-out — the user-facing `/docs` site (the hand-written `priv/docs/*` pages).**
These pages exist to be *read by a human learning or integrating Relay*, and a page that is
simply and clearly stated **beats** strict de-duplication. So any hosted site page MAY restate a
concept, command, or endpoint in its own words when that makes it a clearer standalone read. What
they may **not** do is **drift**: a restated fact must still agree with its canonical source. The
named sources of truth below remain authoritative; a site page is a *view* of them, never a
competing definition. (The `architecture/*` and `runbooks/*` pages *served* on the site are
symlinks whose canonical home is `docs/architecture` / `docs/runbooks`; they follow that home's
current-state, de-dup rules, not this carve-out.)

### The homes

| Home | Reader — and *where they are* | Kind of content | Lifecycle | Published |
| --- | --- | --- | --- | --- |
| `relay.md` | a **driver agent in another repo's context** | how to drive a card via `bin/relay` | current; tiny; shipped out by `bin/relay init` | in every consuming repo |
| `priv/docs/*` | an integrator/operator **browsing a URL** | product + integration reference & onboarding | current | public site |
| `docs/architecture/*` | a **contributor editing this repo** | how the system works **today** | current; freshness-gated | public (symlinked) |
| `docs/adr/*` | anyone **weighing or reviewing a structural change** | a decision + its rationale (the *why*) | durable; immutable once Accepted | internal |
| `docs/glossary.md` | anyone — the **tiebreaker** | vocabulary bound to code | current | internal |
| `docs/vision.md` | product / anyone | the north-star narrative | aspirational | internal |
| `docs/designs/*` | a **UI builder** | hi-fi mockups = visual source of truth | current; re-pulled | internal |
| `docs/runbooks/*` | an **operator** | step-by-step procedure + rollback | current | public (symlinked) |
| `AGENTS.md` + `.claude/skills/*` | the **in-repo agent** | standing rules; executable process | current | internal |

**Published vs internal is now explicit.** Only `architecture` and `runbooks` are symlinked into
`priv/docs/` and served on `/docs`. Anything published is dual-audience (contributor *and* site
reader) and must read acceptably to an outsider. ADRs, vision, glossary, and designs are
repo-internal by decision — they assume repo context and are not for the public site.

### Named sources of truth

When these facts appear anywhere else, that other place links to the home and does not redefine:

- **Vocabulary / term definitions** → `docs/glossary.md`.
- **The four state machines and their transitions** → `docs/architecture/state.md` (the run
  table is generated; never hand-copy it).
- **REST endpoints** → `priv/docs/api.md`. **CLI commands** → `priv/docs/cli.md`.
- **PubSub topics & supervised processes** → `docs/architecture/runtime.md`.
- **"What Relay is" / the north star** → `docs/vision.md`.
- **How work physically runs (dispatch, executor, worktrees)** → `docs/architecture/runner.md`.

### The placement test — "is this in the right home?"

Ask, in order:

1. Is it *"why we chose X over Y"*? → **ADR** (and the rationale lives nowhere else). If it also
   describes how the system works today, that half is **not** ADR material — split it into
   `docs/architecture` and let the ADR link to it.
2. Is it a **term** everyone must use consistently? → **glossary** (others link, never redefine).
3. Does it describe **how the system works right now**, such that a code change could falsify it?
   → **docs/architecture** — and it must be freshness-gated (updated in the same branch as the
   change, per `AGENTS.md`).
4. Is it *"how do I, from outside, do X with Relay"*? → the **hosted `/docs` site** if the reader
   is browsing; **`relay.md`** if it is the context shipped into a driver agent.
5. Is it an **operational ritual** with steps and a rollback? → **runbooks**.
6. Is it what we are **aiming at**, not what exists? → **vision**.
7. Is it a **rule the in-repo agent** must follow while working? → **AGENTS.md** (a standing
   rule) or **a skill** (an executable procedure).

Then the **duplication check**: if the fact already has a home above, this instance links to it —
unless this is a user-facing `/docs` concept page, which may restate it simply but must not drift
from the canonical source.

### ADR conventions (reaffirmed and tightened)

- **An ADR is a decision, not a reference.** It records a choice and its forces. Current-state
  description belongs in `docs/architecture`; an ADR links to it. A doc that is mostly a
  current-state map is misfiled as an ADR.
- **Format:** `Context` / `Decision` / `Consequences` / optional `Alternatives considered`, with
  a `## Status` section carrying status + date. Statuses: `Proposed` → `Accepted` → `Superseded
  by NNNN`. (`Draft` is not a status; use `Proposed`.)
- **Immutable once Accepted.** Amend by superseding, not by editing in place. An Accepted ADR
  with inline `Update (…)` sections is a smell — supersede instead.
- **Keep them short.** An ADR that has grown inventories, sketches, and tool comparisons is
  turning into a design doc; extract the reference parts to their proper home.

## Consequences

- **Reviewers gain a test.** "Where should this doc/change go?" and "is this the right home?"
  become answerable against a written rule instead of taste.
- **Drift becomes the enemy, not duplication.** The site carve-out means we stop policing
  restatement across the hosted `priv/docs/*` pages and start policing *disagreement* with the
  sources of truth. The
  highest-value guardrail to add next is a drift check for the vocabularies that are stated in
  more than one place (status set, category set) — see Known gaps.
- **Some current docs are now "misfiled" and get a target home** (see assessment below). Moving
  them is deferred to a consolidation plan; this ADR only fixes *where things should be*.
- **It must be kept honest.** Like any prose, this can rot. Treat a contradiction between this
  taxonomy and where docs actually live as a bug in one or the other.

## Current-state assessment — the existing docs run through the test

| Doc(s) | Verdict | Target |
| --- | --- | --- |
| `state.md` (generated) | ✓ correct home | source of truth for state machines |
| ADR 0007's hand-drawn transition + `parked_reason` tables | ✗ misfiled reference, un-gated dup | delete the tables; link `state.md` |
| ADR 0007's failure grid (A1–F2) | ✗ current-state reference in an ADR | move to a new `docs/architecture/failures.md` (new hosted slug), gated |
| ADR 0007's decision + 8 known-gaps | ✓ true ADR material | keep; link to the moved grid |
| `domain.md` Runs entry (restates run failure machinery) | ~ partial dup | trim to "what the context owns"; link `state.md` / `runner.md` |
| "What Relay is" in `vision.md`, `README.md`, `introduction.md` | ~ 3 copies | `vision.md` canonical; others may restate (README internal, introduction user-facing) but must not drift |
| Card status: 4 values in `cards-and-handoffs`, 5 in `statuses-and-outcomes` | ✗ **drift** (not mere dup) | reconcile to the glossary's set; both pages link the glossary |
| `category` enum: prose `unstarted` vs API `started` | ✗ **drift** | reconcile prose to the schema's set |
| `authentication.md` (~50% dup of getting-started + api) | ✓ dup allowed (site carve-out) | keep as a clear standalone page; only ensure the mint/bearer details don't drift from api.md |
| `agent-integration.md` (thin over `runner.md`; stale board-runner warning) | ✗ stale + redundant | rescue its unique bits into `runner.md`, then retire; repoint links to `/docs/architecture-runner` |
| `runner.md` (496 lines; contributor internals + executor-author contract) | ~ over the ~2-page cap, dual purpose | candidate split; heavily deep-linked, so move carefully |
| Stale lines: `domain.md` "nothing executes yet", getting-started "RLY-177 planned", `runtime.md` "empty until W9" | ✗ stale | sweep |
| No `docs/README.md` index; published-vs-internal implicit | ✗ missing | add a `docs/` map naming each home + the split |
| ADR hygiene (mixed status headers; 0003 amended in place; `Draft`; no template) | ✗ convention drift | standardize per this ADR; add a template |

## Alternatives considered

- **Strict "one fact, one home" everywhere, including the site.** Rejected for the user-facing
  `priv/docs/*` pages: a page a human reads is worse when every concept, command, or endpoint is a
  link to chase. Clarity for that reader outranks dedup — but only when the restatement doesn't
  drift.
- **Leave the taxonomy implicit and just clean up.** Rejected: without a written test the same
  drift and misfiling recur, and reviewers have no basis to reject a doc in the wrong place.
- **Encode homes as tooling (a linter that assigns files to homes).** Attractive for the two
  measurable drifts (status set, category set) and captured as a Known gap; but most placement
  judgments (decision vs reference vs onboarding) are semantic, not mechanical.

## Known gaps

1. **No automated drift check.** The status set and category set are stated in prose in multiple
   places with no gate; only `state.md`/`deps.md` generated blocks are checked. A small check that
   asserts the documented vocabularies match the schema enums would stop the class of bug this ADR
   only *describes*.
2. **The site carve-out is a judgment call.** "A little duplication" across the `priv/docs/*`
   pages has no bright line; it relies on reviewers distinguishing *helpful restatement* from
   *drift*. If it's abused, tighten it.
3. **`runner.md`'s dual audience** (contributor internals vs executor-author contract) may warrant
   a real split; deferred because `relay.md` and other docs deep-link into it.
