# ADR 0008 — Documentation taxonomy: what lives where, and why

## Status

Accepted

## Context

Hamaca's prose lives in several homes: `hamaca.md`, the public `/docs` site (`priv/docs/`),
`docs/architecture/`, `docs/adr/`, `docs/glossary.md`, `docs/vision.md`, `docs/designs/`,
`docs/runbooks/`, and the in-repo agent instructions (`AGENTS.md` and `.claude/skills/`). Each
serves a different reader. Without written boundaries, the same fact gets written in several
homes and the copies drift apart: a state machine drawn three times, a status list with four
values on one page and five on another. A drifted copy is worse than no copy, because a reader
can't tell which one is right.

The code already has a rule for this: a magic value is defined exactly once (`AGENTS.md`). Prose
needs the same rule.

## Decision

**One fact, one home; everywhere else links.** Every documented fact has one canonical home.
Anywhere else that needs it links to that home instead of restating it.

**The public `/docs` site may restate, but never drift.** The hand-written `priv/docs/` pages are
read by people learning or integrating Hamaca, and a page that's clear on its own beats one made
of links. So a site page may restate a concept, command or endpoint in its own words. It must
agree with the canonical source. Where a site page lists a closed set (statuses, outcomes,
categories), the list is checked against the code: a `vocab:` marker on a markdown table, or a
HEEx page that renders the set from the schema function.

**The map lives in [`docs/README.md`](../README.md).** It names each home, who it's for, what goes
there, whether it's published, the named sources of truth, and the placement test for deciding
where something new belongs. Only `docs/architecture/` and `docs/runbooks/` are published on the
site, through committed symlinks; the rest of `docs/` is internal.

**ADRs are decisions, kept current.** An ADR states a decision that holds today and why. How the
system works in detail belongs in `docs/architecture/`, and the ADR links to it. When a decision
changes, its ADR is edited in place; when it stops applying, the ADR is deleted. The format is
in [`README.md`](README.md) and [`TEMPLATE.md`](TEMPLATE.md).

## Consequences

- "Where does this go?" has a written answer, so a reviewer can reject a doc in the wrong home
  instead of arguing taste.
- On the site, the thing to police is disagreement, not repetition. Closed sets are checked by
  tests; everything else depends on review, so the carve-out is a judgment call that has to be
  tightened if it's abused.
- `docs/architecture/` pages must change in the same branch as the code they describe, and so
  must any ADR the change contradicts.
- `test/hamaca/docs_taxonomy_test.exs` holds the map and the ADR format to this decision.

## Alternatives considered

- **Strict one-home everywhere, including the site.** Rejected for `priv/docs/`: a reader
  learning the product shouldn't have to chase a link for every concept.
- **Leave it implicit and clean up now and then.** Rejected: without a written rule the same
  drift comes back, and a reviewer has nothing to point to.

## Open questions

- `docs/architecture/runner.md` (about 2,200 lines) serves two readers: contributors working on
  the engine, and anyone writing a runner against its contract. Splitting it would help both,
  but many docs deep-link into it, so the split hasn't been made.
