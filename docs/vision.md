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

Relay makes the hand-off the center of the product, and it does so through the **columns**.
Each stage of the board is owned by either **humans** or **AI** — a stage is a human-run lane
or an AI-run lane. A card's current holder is simply **whoever owns the stage it sits in**, so
the baton passes every time a card moves across a hand-off between a human stage and an AI
stage.

- **In a human stage** — a person is doing the work, or the card is waiting on a human decision.
- **In an AI stage** — an AI agent is working the card (or queued to). While it works, the
  card shows live progress; if it hits a decision it can't make, it **blocks and asks** rather
  than guessing, and the human answers inline. Human owners are "paused" while the AI works.

Work flows by **passing the baton**: a human scopes a card in a human stage and moves it into
an AI stage; the agent does a pass and returns it to a human review stage; the human approves
it forward or sends it back for the AI to address. The board shows, at a glance, what's *on
you*, what's *on an agent*, and what's *blocked*.

This turns a kanban board from a passive record into an active workspace where humans and
agents are peers on the same cards — and where the *shape of the board* is the workflow.

## Principles

1. **Ownership is a first-class property of stages.** Each stage is human-run or AI-run; a
   card's holder follows its stage, and the history of hand-offs is core data — not metadata
   bolted on. Model it explicitly.
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

- **Board** — a workspace containing stages and cards.
- **Stage** — a column of work with two orthogonal properties: an **owner** (`human` or `ai`)
  and a **category** (`unstarted` / `in progress` / `complete`, à la Linear) so its meaning is
  unambiguous. Stages can carry a WIP limit and act as an approval gate.
- **Card** — a unit of work (title, description, tag, sub-tasks, comments, activity). Its
  **owner is derived from its stage**; it also carries a **status** (`queued` / `working` /
  `needs input` / `in review` / `done`) and a hand-off history.
- **Agent** — an AI worker (the "Relay AI" member) that holds the baton while a card is in an
  AI stage, reports progress and results, asks when unsure, and hands the card back.
- **Hand-off** — a card moving between a human stage and an AI stage, carrying its context
  (description, comments, results) across.

## What this is not (yet)

- Not a general chatbot bolted onto a board — the unit of collaboration is the **card**, not
  a conversation.
- Not an offline-first mobile app today (see ADR 0001).
- Not a fixed feature list — this document is the north star the roadmap is measured against.
