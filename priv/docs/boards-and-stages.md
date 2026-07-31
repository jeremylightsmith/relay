# Boards & stages

A **board** is a workspace containing stages and cards. It is the accountability surface: it
shows at a glance what's *on you*, what's *on an agent*, and what's *blocked*.

## Stages

A **stage** is a column of work with two orthogonal properties:

- an **owner** — `human` or `ai` — which decides who holds a card while it sits there, and
- a **category**, so its meaning on the board is unambiguous:

<!-- vocab: Schemas.Stage.categories/0 -->

| Category | A card sitting here is… |
| --- | --- |
| `unstarted` | not begun — an idea, a backlog item, something queued up next |
| `planning` | being specified or designed, not yet being built |
| `in_progress` | actively being worked |
| `complete` | finished — shipped, or archived |

A stage can also carry a **WIP limit** and act as an **approval gate**.

> [!TIP]
> Ownership is a property of the **stage**, not the card. A card's holder always follows its
> stage, so moving a card across a human↔AI boundary *is* the hand-off.

## Human vs. AI stages

- **Human stages** are lanes where people work or decide. AI owners are "paused" here.
- **AI stages** are lanes where the Relay AI agent works — or is queued to. While it works, the
  card streams live progress; when it needs a call it can't make, it blocks and asks.

## Review and Done

Many workflows add a `*:Review` sub-lane — a human checkpoint where the agent stops and waits
for approval — before a `*:Done` sub-lane that auto-continues into the next AI stage. The
board's sub-lane layout *is* the human-checkpoint configuration.
