# Cards & handoffs

A **card** is a unit of work — a title, description, tag, sub-tasks, comments, and activity.

## Status and ownership

A card's **owner is derived from its stage**. On top of that it carries a **status**:

| Status | Meaning |
| --- | --- |
| `ready` | Not actively being worked — sitting wherever it is |
| `working` | An agent (or person) is actively on it |
| `needs_input` | Blocked on a human answer |
| `in_review` | Waiting at a human approval gate |

> [!NOTE]
> **Done is derived, not a status.** A card is *done* once a `ready` card is parked at the
> board's terminal (rightmost) stage — there is no `done` status to set.

## Whose turn is it?

Every card surfaces a `needs_you` fact, so it's always obvious whether the next move is yours.
When an agent needs a decision it calls out and the card blocks until you answer in the drawer.

## Hand-offs

A **hand-off** is a card moving between a human stage and an AI stage, carrying its context —
description, comments, and results — across. A human scopes a card and moves it into an AI
stage; the agent does a pass and returns it to a human review stage; the human approves it
forward or sends it back.
