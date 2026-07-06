# Relay — Product Vision

## One line

**Relay is an AI-first kanban board where work is a baton passed back and forth between
humans and AI agents.**

## The problem

AI agents can now do real work — draft, research, code, summarize, plan. But most tools
treat AI as a side panel: a chat you copy out of, disconnected from where the work actually
lives. Meanwhile the work itself (a task, a card, a ticket) has no notion of *who is holding
it right now* or *whose move is next*. Collaboration between a person and an agent degrades
into copy-paste and lost context.

## The idea: passing the baton

Relay makes the hand-off the center of the product. Every card carries a **baton** — an
explicit answer to "whose turn is it?":

- **Human holds it** — a person is doing the work, or the card is waiting on a human decision.
- **Agent holds it** — an AI agent is actively working the card (researching, drafting,
  executing), or is queued to.

Work flows by **passing the baton**: a human scopes a card and hands it to an agent; the
agent does a pass and hands it back for review; the human refines and re-delegates, or moves
it forward. The board shows, at a glance, what's *on you*, what's *on an agent*, and what's
*blocked*.

This turns a kanban board from a passive record into an active workspace where humans and
agents are peers on the same cards.

## Principles

1. **The baton is a first-class property.** Who holds a card (human vs. agent), and the
   history of hand-offs, is core data — not metadata bolted on. Model it explicitly.
2. **Hand-offs are explicit and legible.** It should always be obvious whose move it is and
   why. No silent "the AI did something somewhere."
3. **Real-time by default.** When an agent picks up, works, or returns a card, everyone
   watching the board sees it live. (This is why the app is built on Phoenix LiveView.)
4. **Humans stay in control.** Agents propose and execute within scope; humans decide what
   moves forward. The board is the accountability surface.
5. **One workspace, everywhere.** The same board and the same hand-off model on web and
   mobile — see [ADR 0001](adr/0001-client-architecture.md) for how we deliver that without
   duplicating the client.

## Core concepts (working model)

These are the nouns the product is organized around. They will be refined as we build — this
is direction, not a schema.

- **Board** — a workspace containing columns and cards.
- **Column** — a stage of work (the usual kanban lanes).
- **Card** — a unit of work. Beyond the usual title/description, a card has a **baton
  holder** (`human` or `agent`) and a **hand-off history**.
- **Agent** — an AI worker that can hold the baton on a card, do a pass, and hand it back
  with its output attached.
- **Hand-off** — the event of passing a card between a human and an agent (or between
  agents), with context carried across.

## What this is not (yet)

- Not a general chatbot bolted onto a board — the unit of collaboration is the **card**, not
  a conversation.
- Not an offline-first mobile app today (see ADR 0001).
- Not a fixed feature list — this document is the north star the roadmap is measured against.
