# How Hamaca works

A Hamaca board looks like any kanban board: columns of cards, left to right. The difference is
that agents work some of the columns. Your board shows you, at a glance, which cards an agent
is working, which ones are waiting on you, and which ones are stuck.

## Follow one card

Here's the board the Bare minimum template gives you:

| Backlog | Next up | Plan | Implement | Review | Deploy | Done |
| --- | --- | --- | --- | --- | --- | --- |
| ideas | ready to start | agent | agent | you | you | finished |

Plan and Implement each have a *flow*: the steps an agent follows to work a card in that
column. The other columns are yours.

Say you add a card, "Export the board as CSV", to Backlog. Here's its trip:

1. You move it to Next up when you want it started. Nothing happens to it until you do.
2. An agent picks it up in Plan. The Plan flow takes cards from Next up. The card turns
   violet while the agent has it, and you can open it and watch the agent work.
3. The agent asks you a question. It isn't sure whether archived cards belong in the
   export. The card turns amber, which means it needs you. You answer on the card, and the
   agent carries on.
4. The plan waits for you in Plan › Review. Read it, then click **Approve** or
   **Request changes**. Request changes asks for a note and sends the card back to Plan for
   another pass.
5. Approve moves it on. It waits in Plan › Done until the Implement flow picks it up, and
   then an agent builds it.
6. You review the work in Review. Approve sends it to Deploy. Request changes sends it back
   to Implement with your note.
7. You ship it and move the card to Done.

## The parts of a board

Columns are stages. Each one is a step your work goes through. Some, like Backlog and Next
up, are just places where cards wait. Some have a flow, so an agent works the cards that reach
them. You can add, rename, and reorder stages in Settings › Stages.

Review and Done are optional parts of a stage. Turn on Review for a stage and the agent
stops there when it finishes, so nothing moves on without your OK. Turn on Done and approved
cards wait there until the next stage picks them up.

Flows decide what agents do. A stage with a flow takes cards from the column before it and
starts an agent on each one. Turn a flow off and that stage becomes yours again.

Cards carry their history. A card's description, comments, questions and answers, and the
agent's results all stay on the card as it moves. Whoever picks it up next has the whole story.

Each kind of stage behaves a little differently:

<!-- vocab: Schemas.Stage.types/0 -->

| Kind | What happens there |
| --- | --- |
| Queue | Cards wait to be started. Backlog and Next up are queues. |
| Planning | Someone works out what to build, such as a spec, a design or a plan. |
| Work | Someone builds or ships it. |
| Review | A person approves the card or sends it back. |
| Done | The card is finished. On the last column, that means finished for good. |

## Reading a card's color

| Color | It means |
| --- | --- |
| Violet | An agent is working the card. |
| Blue | A person has the card. |
| Amber | The card needs you: a question to answer, work to review, or a failed run to look at. |
| Green | The card is done. |

[Statuses & outcomes](/docs/statuses-and-outcomes) has every state a card can be in, and what
to do about each one.

## Where to go next

- [Getting started](/docs/getting-started) gets an agent working your first card.
- [Statuses & outcomes](/docs/statuses-and-outcomes) explains each card state.
