# Architecture Decision Records

Short, durable records of significant, cross-cutting decisions — the *why* behind the
structure. Read the relevant ADR before changing anything it governs; supersede rather than
silently contradict.

Each ADR is numbered and immutable once **Accepted**. To change a decision, add a new ADR
that supersedes the old one (update the old one's status to `Superseded by NNNN`).

| # | Title | Status |
| --- | --- | --- |
| [0001](0001-client-architecture.md) | Client architecture: LiveView-first with a thin native wrapper | Accepted |
| [0002](0002-module-boundaries-and-schemas-peer.md) | Module boundaries (`boundary`) + a `Schemas` peer | Accepted |
| [0003](0003-card-state-stage-type-validity.md) | Card state × stage type validity | Accepted |
| [0004](0004-card-ownership-and-the-claim-rule.md) | Card ownership & the claim rule | Accepted |

## Format

Keep ADRs short. A typical one has: **Context** (the forces at play), **Decision** (what we
chose, stated plainly), **Consequences** (what follows — good and bad), and optionally
**Alternatives considered**.
