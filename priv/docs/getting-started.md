# Getting started

When you create a board, a setup checklist opens beside it. Follow it, and by the end an agent
will be working your first card. This page walks through the same steps, so
you know what's coming.

You'll need:

- a git repository on your computer that you're happy to let agents create branches in;
- Claude Code (recommended) or Codex.

You don't need the Hamaca source code. Everything comes from your board.

## 1. Create a board

Sign in at [hamaca.app](https://hamaca.app), or at your own server if you self-host, and create
a board from a template. The setup checklist opens beside it and ticks off each step as you go.

## 2. Pick your LLM

Choose the coding agent that will work your cards. Claude Code is the best tested. You can
change it later in Board settings → Agents.

## 3. Copy your key

The checklist shows a line with your board's key in it:

```bash
export RELAY_API_KEY=relay_xxxxxxxxxxxx_…
```

Copy it now, because it's only shown once. Put it where your shell will load it, such as your
shell profile or a gitignored `.envrc.local`.

## 4. Install in your repo

The checklist gives you an install command for your board. Run it from your repo's root
folder:

```bash
curl -fsSL "https://<your-board-host>/b/<board>/install" | sh
```

It checks your repo before writing anything. Then it adds `./relay`, the tool that runs agents
on your machine, and a few files that tell your agent how to work with Hamaca. It doesn't commit
anything.

## 5. Onboard with your agent

Open Claude Code in your repo and run:

```
/relay-onboard
```

It asks a few questions about your project, shows you each change before making it, turns on
your board's flows (the steps an agent follows in each stage) and creates your first card. The checklist ticks off each part as it goes.
If you stop partway, run it again and it picks up where it left off.

## 6. Start the runner

Open a new terminal in your repo and run:

```bash
./relay start
```

Leave it running. The runner is what picks up cards and starts agents on them. Within a few
seconds the checklist shows your machine as online.

## 7. Watch your first card

The runner picks up the card that onboarding created, and the card turns violet: an agent has
it. Open the card and select the **Run** tab to watch the agent work.

If the agent hits a decision it can't make, it asks you on the card. Answer there and it
carries on. When it's done, the card moves to the next stage by itself.

That's setup. From here, add cards to your board and move them into a stage that has a flow.

## When a card doesn't move

If a card sits in a stage's *Next up* lane, it's almost always one of these. Check them in
order.

1. **The stage has no flow turned on.** Open Settings › Stages and check that the stage's flow
   is on.
2. **The runner isn't running.** Open the board's Runners page. Your machine should show
   FRESH. If it shows STALE or GONE, or isn't listed, restart `./relay start` in a terminal
   where `RELAY_API_KEY` is set.
3. **The runner can't take this kind of work.** Code cards need a runner with `exclusive`
   capacity. The Runners page shows what each machine can take, and
   [Runner config](/docs/cli#runner-config) shows how to change it.
4. **The card is waiting on you.** If an agent asked a question, the card shows it. Answer it
   on the card.

Still stuck? Run `./relay why <card>` and it tells you why that card isn't moving.

## Where to go next

- [How Hamaca works](/docs/how-hamaca-works) follows one card across a board, from you to an
  agent and back.
- [CLI](/docs/cli) lists every `./relay` command.
- [REST API](/docs/api) is for building your own tools on Hamaca.
