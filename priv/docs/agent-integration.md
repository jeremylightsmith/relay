# Agent integration

`bin/relay` is two things in one: a **CLI** for driving a card by hand, and a **board runner**
that watches the board and drives *ready* cards through a pipeline autonomously — "passing the
baton" between humans and AI.

## The runner

Run `bin/relay watch` and it polls the board and, on any change, works the single **rightmost
ready** card one hop, then re-polls. It is cheap when idle: it fingerprints the board and only
spends model tokens when there's real work.

1. **Pull** the rightmost ready card (the column to its right is an AI column).
2. **Work** one stage — a reasoning stage runs headless Claude; mechanical steps run shell.
3. **Hand back** by pushing to the next column (`*:Review` to stop for a human, `*:Done` to
   auto-continue).

```bash
bin/relay watch            # live 🤖/🔧 play-by-play
bin/relay watch --once     # a single pass
bin/relay watch --dry-run  # no tokens, no mutations
```

> [!TIP]
> The pipeline — which columns are AI columns, what runs at each, and where finished work goes
> — lives entirely in `relay_config.json`. `bin/relay` knows the API and how to dispatch but
> nothing about your board's columns; customise the runner by editing config, not code.

## Operating invariants

If you build your own runner or agents, honour these — break one and cards corrupt each
other's work:

1. **One agent per working directory at a time.** A `git checkout` is global to the directory;
   serialise, or give each agent its own clone or `git worktree`.
2. **State lives on the board, never in the working tree.** Many cards are in flight; nothing
   durable may depend on what's currently checked out.
3. **Each card owns its branch** — check it out at the start of a step, commit at the end.
4. **Work travels with the card.** The spec is the card's `description`; the plan is its `plan`
   field. Materialise them into the branch just-in-time.

> [!WARNING]
> **On failure, flag the card — never retry-loop.** Set the card to `needs_input` with the
> reason. Blocked cards are skipped, so a flagged card waits for a human instead of looping.

See the repository's `docs/agent-integration.md` for the full runner reference and the
`relay_config.json` schema.
