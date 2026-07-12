# Introduction

**Relay is an AI-first kanban board where work is a baton passed back and forth between
humans and AI agents.**

Most tools treat AI as a side panel — a chat you copy out of, disconnected from where the
work lives. Relay makes the **hand-off** the center of the product: every card knows *who is
holding it* and *whose move is next*.

## Passing the baton

Each stage (column) of a board is owned by either **humans** or **AI**. A card's current
holder is simply whoever owns the stage it sits in, so the baton passes every time a card
crosses a hand-off between a human stage and an AI stage.

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

- New to the model? Read [Boards & stages](/docs/boards-and-stages) and
  [Cards & handoffs](/docs/cards-and-handoffs).
- Building an agent? Jump to [Setup](/docs/setup) and the [CLI](/docs/cli).
