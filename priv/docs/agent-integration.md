# Agent integration

`bin/relay` is two things in one: a **CLI** for driving a card by hand, and a **node-job
executor** (`bin/relay execute`) that claims work from the server's flow engine and runs it —
"passing the baton" between humans and AI.

## The runner

Dispatch is entirely server-side: which cards are ready, which flow they run, and what each
step does are `Flow` rows owned by the board's scheduler, editable in **Settings › Flows**.
`bin/relay execute` knows nothing about any particular board's columns, agents, or skills — it
just claims the node-jobs the server hands it and runs them, in an executor-owned git worktree.

1. **Claim** the next node-job from the server (a long-poll — cheap when idle).
2. **Run** it — an agent node runs headless Claude; `shell`/`gate` nodes run shell.
3. **Report** the outcome back to the server, which advances the flow (moving the card to the
   next column when the flow lands there).

```bash
bin/relay execute            # live 🤖/🔧 play-by-play
bin/relay execute --once     # a single claim-and-run pass
bin/relay execute --dry-run  # no tokens, no mutations
```

> [!TIP]
> Per-board customization — which stages are AI-enabled, what each node does, and where
> finished work goes — lives entirely in **Settings › Flows**, not in a runner config file.
> `bin/relay` is generic across boards; customise the flow, not the code.

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

See the repository's `docs/agent-integration.md` and `docs/architecture/runner.md` for the
full runner reference.
