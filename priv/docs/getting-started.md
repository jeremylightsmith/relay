# Getting started

**From nothing to a card being worked by agents.** Follow the steps in order — each one
is a board URL, a click in the UI, or a command you already have. Nothing here needs
access to Relay's own source repository.

This page is written so an **agent** can follow it. Where you need a human to decide
something, it is called out **as a question**.

## 1. Create a board

Sign in at your board host and create a board. **That is the whole of setup.** Creating a
board seeds:

- its **stages** (columns) and their human/AI ownership;
- the **Spec:Review**, **Spec:Done** and **Plan:Done** lanes;
- the **default flows** — Spec, Plan and Code.

There is no setup wizard to look for, and nothing to import. The seeded flows arrive
**disabled**; step 5 is where you turn one on.

Note your board's URL — it looks like `https://<board-host>/board/<slug>`. The `<slug>`
appears in every board URL below.

## 2. Get a board API key

Open **Settings → API keys** on your board (`/board/<slug>/settings`) and click **+ Create
new key**. It is shown **once** — copy it now. If a key already exists, **Regenerate**
replaces it.

Point your shell at the board with two environment variables:

```bash
export RELAY_URL="https://<board-host>"
export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
```

Put them somewhere your agent's shell will load them — a gitignored `.envrc.local`, your
shell profile, or your process manager's environment. Every command below reads them.

See [Authentication & API access](/docs/authentication) for what the key authorises and
the error you get without it.

## 3. Get the CLI and scaffold your project

Everything the CLI needs is served by **your board** — **no access to the Relay repository is
needed**, there is no repository to clone, and nothing comes from a third party.

Download the `/relay-setup` skill into your project, then run it inside Claude Code:

```bash
mkdir -p .claude/skills/relay-setup
curl -fsSL "$RELAY_URL/api/scaffold/.claude/skills/relay-setup/SKILL.md" \
  -o .claude/skills/relay-setup/SKILL.md
```

```
/relay-setup
```

That is the whole of CLI setup. `/relay-setup` downloads `bin/relay` from
`$RELAY_URL/api/scaffold/bin/relay` and runs `bin/relay update` to install the four Relay-owned
skills. Because a skill written mid-session is not discoverable until the skill list is rebuilt,
it then asks you to **restart Claude Code** and run `/relay-onboard`, which wires this repo to
your board's flows. `/relay-onboard` also authors `relay.md` and `.relay/executor.json` for this
repo if either is missing — that `.relay/executor.json` is where step 4's capacity configuration
comes from.

Relay owns exactly five files in your project and updates them as a set:

| Item | Path |
|---|---|
| the executor | `bin/relay` |
| entry-point skill | `.claude/skills/relay-setup/SKILL.md` |
| updater skill | `.claude/skills/relay-update/SKILL.md` |
| doctor skill | `.claude/skills/relay-doctor/SKILL.md` |
| onboarding skill | `.claude/skills/relay-onboard/SKILL.md` |

Everything else in `.claude/` is yours; Relay never writes it.

Already have `bin/relay`? Run `/relay-update` (or `bin/relay update --check` to see what would
change first). It compares the board's scaffold manifest against what is on disk, refetches only
what actually differs, and restores anything that has been deleted or edited.

**Question for a human:** which project directory should agents work in? It must be a git
repository, and it should be one you are willing to let agents create branches in.

## 4. Start the executor

From that project directory:

```bash
relay execute
```

The executor claims work from your board and runs it. It knows nothing about your board's
particular columns or agents — the server tells it what to do, so it stays generic. It
long-polls when idle, so leaving it running is cheap.

**Confirm it is advertising capacity** before moving on. Open the **Runners** view at
`/board/<slug>/runners`. Your machine should appear with a **FRESH** pill and capacity
chips showing its configured totals. If it does not appear at all, `relay execute` is not
reaching the board — re-check `RELAY_URL` and `RELAY_API_KEY` from step 2.

Capacity comes from `.relay/executor.json`'s `capacity` and is advertised on a heartbeat
every few seconds. Two classes matter:

- `shared_clean` — jobs that can share one clean worktree;
- `exclusive` — jobs that need a worktree to themselves. The Code flow needs this one.

## 5. Enable a flow

Flows are seeded **disabled**, so nothing dispatches until you turn one on. Open
**Settings › Flows** on your board and enable the **Spec** flow — it is the cheapest one
to start with, and it is the first stage a new card meets.

The confirm dialog reminds you that a runner must be connected and advertising capacity
before cards will move — it does not check for you, so confirm that yourself on the
**Runners** view (step 4).

Read [Enabling a flow safely](/docs/runbook-flow-cutover) before you enable a flow on a
board that already has cards moving through it — the ordering there is what keeps two
dispatchers off the same cards.

**Question for a human:** which stages do you want agents to own? Enabling a flow hands
that stage's cards to agents. Start with one.

## 6. Move a card into *Next up* and watch it work

Create a card on the board and drag it into the Spec stage's **Next up** lane. Within a
few seconds the card should pick up a **Run**: open the card's drawer and select the
**Run** tab to watch the agent work, live.

When the flow finishes, the card moves itself to the next stage. If the agent hits a
decision it cannot make, it sets the card to **needs input** and asks you a question in the
drawer — answer it there and the run resumes.

See [Statuses & outcomes](/docs/statuses-and-outcomes) for what each state means.

## 7. When a card does not move

A card that just sits in *Next up* is almost always one of four things. Check them in this
order:

1. **No flow is enabled for that stage.** Open **Settings › Flows** and confirm the flow
   covering that card's stage is on. This is the most common cause on a new board.
2. **No executor is advertising capacity.** Open `/board/<slug>/runners`. If the roster is
   empty, or your machine shows **STALE** or **GONE** rather than **FRESH**, `relay execute`
   has stopped or lost the board — restart it and re-check.
3. **The executor has capacity, but not the right class.** A Code-flow card needs
   `exclusive` capacity. Check the capacity chips on the Runners view against what the flow
   needs.
4. **The card is blocked on you.** A card in **needs input** is waiting for a human answer,
   not for an agent. Open its drawer and answer the question.

If none of those explain it, open the card's drawer **Run** tab: a run that started and
failed shows the node that failed and its outcome there.

> [!TIP]
> There is a dedicated diagnosis surface for exactly this question: run `bin/relay why <ref>`,
> or read `GET /api/cards/:ref/diagnosis`. It answers "why isn't this card moving?" in one call
> instead of four checks by hand.

## Where to go next

- New to the model? [Boards & stages](/docs/boards-and-stages) and
  [Cards & handoffs](/docs/cards-and-handoffs).
- Driving a card by hand? The [CLI](/docs/cli).
- Building your own runner or agents? [The runner](/docs/architecture-runner) and the
  [REST API reference](/docs/api).
