# Statuses & outcomes

Relay is about **passing the baton**: work moves back and forth between you and AI agents,
and the board makes the hand-off explicit. Two small vocabularies carry that — a card's
**status**, and the **outcome** an agent declares when it finishes a step. Learn these five
and four words and the board reads itself.

## What a card's status means

| Status | Colour of the situation | What you do |
| --- | --- | --- |
| **Ready** | Nothing is running. The card is available. | Move it, or let the board pick it up. |
| **Queued** | The board has picked the card but work hasn't started. | Nothing — it starts on its own. |
| **Working** | An agent holds the baton and is working the card. | Nothing. Watch the live output on the card if you like. |
| **Needs input** | The agent has a question. The baton is back with **you**. | Open the card and answer in the drawer. Work resumes where it stopped. |
| **In review** | The card is at a review gate. | Approve it to the next stage or substage, or send it back with a note. |

Only **Needs input** and **In review** actually want something from you — those are the two
that show up in your "needs you" rollup.

## What an agent declares when it finishes

Every step an agent runs ends with exactly one of four outcomes. This is what decides where
the card goes next.

| Outcome | Meaning | What happens |
| --- | --- | --- |
| **Succeeded** | The step did what it was asked. | The card moves on to the next step. |
| **Failed** | The step could not do it. | The board retries a bounded number of times, then stops and puts the card in front of you with the reason. |
| **Partial** | Some of it got done. | The flow routes it wherever that flow says partial work should go — often to a review or a follow-up step. |
| **Needs input** | The agent needs a human decision to continue. | Work pauses and the card goes to **Needs input** with the question. Answering it resumes the same step. |

A step that finishes without declaring anything counts as **Failed** — the board would rather
hand you a stopped card than quietly pretend a step ran.

## Going deeper

This page is the working vocabulary. The full transition tables — including run status,
node-job state, and exactly what each outcome does to both the run and the card — are in the
[state reference](/docs/architecture-state).
