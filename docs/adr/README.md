# Architecture Decision Records

Short records of the significant, cross-cutting decisions that hold today, and why. Read the
relevant ADR before changing anything it governs.

An ADR is current, not a history. When a decision changes, edit its ADR in place so it says
what's true now, in the same branch as the change. When a decision no longer applies,
delete the ADR and its row below. Git history is the record of how a decision got here, so an ADR
never carries dated "as built", "amendment", "refined by" or "superseded" sections. Two ADRs
must never contradict each other or the code; if they do, fix whichever is wrong.

| # | Title | Status |
| --- | --- | --- |
| [0001](0001-client-architecture.md) | Client architecture: LiveView-first, with a hybrid mobile app | Accepted |
| [0002](0002-module-boundaries-and-schemas-peer.md) | Module boundaries (`boundary`) + a `Schemas` peer | Accepted |
| [0003](0003-card-state-stage-type-validity.md) | Card state × stage type validity | Accepted |
| [0004](0004-card-ownership-and-the-claim-rule.md) | Card ownership & the claim rule | Accepted |
| [0005](0005-mobile-app-scope-and-architecture.md) | Mobile app: a decision companion, native where it decides | Accepted |
| [0006](0006-workflow-orchestration.md) | Workflow orchestration: Hamaca owns the graph, developers own the nodes | Accepted |
| [0007](0007-card-lifecycle-and-failure-states.md) | Card lifecycle: the happy path and every failure mode | Accepted |
| [0008](0008-documentation-taxonomy.md) | Documentation taxonomy: what lives where, and why | Accepted |
| [0009](0009-test-isolation.md) | Test isolation: process-tree dependencies and explicit sandbox ownership | Accepted |
| [0010](0010-serving-the-scaffold-from-the-app.md) | The board serves the scaffold | Accepted |
| [0011](0011-simplifying-the-factory.md) | Simplifying the factory: the task is the unit of record | Accepted |
| [0012](0012-board-owners-pay-up-front.md) | Board owners pay up front, on their own billing date | Accepted |
| [0013](0013-the-free-plan.md) | The Free plan | Accepted |
| [0014](0014-talk-as-a-second-execution-lane.md) | Talk: a person-driven execution lane | Accepted |

## Format

Start from [`TEMPLATE.md`](TEMPLATE.md). Keep ADRs short. Each has **Status**, **Context**
(the forces at play), **Decision** (what we chose, stated plainly), **Consequences** (what
follows, good and bad), and optionally **Alternatives considered** and **Open questions**. Use
the `## Status` section form, never an inline `**Status:**` line. The status is `Proposed` or
`Accepted`, and the index's Status cell matches it exactly.

An ADR is a decision, not a reference: how the system works in detail belongs in
`docs/architecture/`, and the ADR links to it.
