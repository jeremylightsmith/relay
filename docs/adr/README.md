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
| [0005](0005-mobile-app-scope-and-architecture.md) | Mobile app: scope & hybrid native-shell architecture | Proposed |
| [0006](0006-workflow-orchestration.md) | Workflow orchestration: Relay owns the graph, developers own the nodes | Proposed |
| [0007](0007-card-lifecycle-and-failure-states.md) | Card lifecycle: the happy path and every failure mode | Proposed |
| [0008](0008-documentation-taxonomy.md) | Documentation taxonomy: what lives where, and why | Proposed |
| [0009](0009-test-isolation.md) | Test isolation: process-tree dependencies and explicit sandbox ownership | Proposed |
| [0010](0010-serving-the-scaffold-from-the-app.md) | The board serves the scaffold | Proposed |

## Format

Start from [`TEMPLATE.md`](TEMPLATE.md). Keep ADRs short. A typical one has: **Status**,
**Context** (the forces at play), **Decision** (what we chose, stated plainly), **Consequences**
(what follows — good and bad), and optionally **Alternatives considered**. Use the `## Status`
section form, never an inline `**Status:**` line.

> **Known exception.** ADR 0003 was amended in place after being Accepted, against the
> immutability rule above. It is recorded here rather than rewritten — rewriting it now would
> compound the problem. Future changes to that decision supersede it with a new ADR.
