# Introduction

**Hamaca is an AI-first kanban board where work is a baton passed back and forth between
humans and AI agents.**

Most tools treat AI as a side panel — a chat you copy out of, disconnected from where the
work lives. Hamaca makes the **hand-off** the center of the product: every card knows *who is
holding it* and *whose move is next*.

## Passing the baton

Every card has owners: the people and agents who can work it. Whoever is acting on it right
now holds the baton. A stage (column) belongs to the AI when a flow is set up to work the cards
in it; every other stage is yours. So the baton passes when a card moves between the two, and
also when an agent stops to ask you something.

- **In a human stage**, a person is doing the work, or the card is waiting on a human decision.
- **In an AI stage**, an agent works the card and streams live progress. If it hits a decision
  it can't make, it **blocks and asks** rather than guessing — and you answer inline.

> [!NOTE]
> Colour encodes the actor: **Human = blue**, **AI = violet**, Done = green, Blocked = amber.
> The palette is the product idea, not decoration.

## Why it matters

This turns a kanban board from a passive record into an active workspace where humans and
agents are peers on the same cards — and where the *shape of the board* is the workflow.

## Next steps

- New to the model? Read [How Hamaca works](/docs/how-hamaca-works).
- Building an agent? Jump to [Getting started](/docs/getting-started) and the [CLI](/docs/cli).
