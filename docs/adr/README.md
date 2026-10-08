# Architecture Decision Records

Short, durable records of significant, cross-cutting decisions — the *why* behind the
structure. Read the relevant ADR before changing anything it governs; supersede rather than
silently contradict.

Each ADR is numbered and immutable once **Accepted**. To change a decision, add a new ADR
that supersedes the old one (update the old one's status to `Superseded by NNNN`).

| # | Title | Status |
| --- | --- | --- |
| [0001](0001-client-architecture.md) | Client architecture: LiveView-first with a thin native wrapper | Accepted (2026-07-06) |
| [0002](0002-module-boundaries-and-schemas-peer.md) | Module boundaries (`boundary`) + a `Schemas` peer | Accepted (2026-07-07) |
| [0003](0003-card-state-stage-type-validity.md) | Card state × stage type validity | Accepted (2026-07-11) |
| [0004](0004-card-ownership-and-the-claim-rule.md) | Card ownership & the claim rule | Accepted (2026-07-11) |
| [0005](0005-mobile-app-scope-and-architecture.md) | Mobile app: scope & hybrid native-shell architecture | Accepted (2026-07-16) |
| [0006](0006-workflow-orchestration.md) | Workflow orchestration: Relay owns the graph, developers own the nodes | Accepted (2026-07-18) |
| [0007](0007-card-lifecycle-and-failure-states.md) | Card lifecycle: the happy path and every failure mode | Accepted (2026-07-31) |
| [0008](0008-documentation-taxonomy.md) | Documentation taxonomy: what lives where, and why | Accepted (2026-07-31) |
| [0009](0009-test-isolation.md) | Test isolation: process-tree dependencies and explicit sandbox ownership | Accepted (2026-08-07) |
| [0010](0010-serving-the-scaffold-from-the-app.md) | The board serves the scaffold | Accepted (2026-08-10) |
| [0011](0011-simplifying-the-factory.md) | Simplifying the factory: the task is the unit of record | Proposed (2026-09-24) |

## Format

Start from [`TEMPLATE.md`](TEMPLATE.md). Keep ADRs short. A typical one has: **Status**,
**Context** (the forces at play), **Decision** (what we chose, stated plainly), **Consequences**
(what follows — good and bad), and optionally **Alternatives considered**. Use the `## Status`
section form, never an inline `**Status:**` line. The index's Status cell mirrors the file's status line
exactly, date included (`Accepted (2026-07-06)`).

Under `## Status`, the status line may be followed by an `**Implementation:**` line —
`**Implementation:** complete.` or `**Implementation:** partial — remaining: <items>.` — and an
optional `## As built (YYYY-MM-DD)` section placed directly after Status records where the shipped
design differs, without editing Context, Decision or Consequences. That section is allowed on an
Accepted ADR because it reports on the decision rather than amending it.

> **Known exception.** ADR 0003 was amended in place after being Accepted, against the
> immutability rule above. It is recorded here rather than rewritten — rewriting it now would
> compound the problem. Future changes to that decision supersede it with a new ADR.
