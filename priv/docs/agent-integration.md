# Agent integration

`bin/relay` is two things in one: a **CLI** for driving a card by hand (see the
[CLI reference](/docs/cli) and the scaffolded `relay.md`), and a **node-job executor**
(`bin/relay execute`) that claims work from the server's flow engine and runs it — "passing the
baton" between humans and AI. This page is the full reference for the executor side: how it
runs, the contract every node runs under, and the invariants your own nodes must honor.

## The runner

Dispatch is entirely server-side: which cards are ready, which flow they run, and what each
step does are configured per-board in **Settings › Flows**. `bin/relay execute` knows nothing
about any particular board's columns, agents, or skills — it just claims the node-jobs the
server hands it and runs them, in an executor-owned git worktree.

1. **Claim** the next node-job from the server (a long-poll — cheap when idle).
2. **Run** it — an agent node runs headless Claude; `shell`/`gate` nodes run shell.
3. **Report** the outcome back to the server, which advances the flow (moving the card to the
   next column when the flow lands there).

```bash
bin/relay execute            # live 🤖/🔧 play-by-play
bin/relay execute --once     # a single claim-and-run pass
bin/relay execute --dry-run  # no tokens, no mutations
bin/relay execute --interval 10   # override the configured poll timeout
```

Agent steps run headless Claude, which uses whatever authentication the local Claude CLI has —
a **Claude subscription** (no `ANTHROPIC_API_KEY` needed) or, if `ANTHROPIC_API_KEY` is set, the
metered API. Subscription rate limits are the ceiling; when hit, the step is throttled, not
silently billed to the paid API.

> [!TIP]
> Per-board customization — which stages are AI-enabled, what each node does, and where
> finished work goes — lives entirely in **Settings › Flows**, not in a runner config file.
> `bin/relay` is generic across boards; customize the flow, not the code.

### Configuring the executor

`bin/relay execute` is configured by `.relay/executor.json`:

```json
{
  "namespace": "exec",
  "capacity": { "shared_clean": 3, "exclusive": 1 },
  "poll_timeout": 25,
  "heartbeat_interval": 15,
  "cache_dir": "~/.relay/cache",
  "prepare": ".relay/prepare-worktree.sh",
  "max_retained_failed": 3
}
```

`name` defaults to the hostname, `namespace` to `exec`; a missing file falls back to
`capacity: {shared_clean: 1, exclusive: 1}`. `capacity` is the field you'll routinely edit — it
caps how many `shared_clean` jobs and how many `exclusive` run-slots this executor advertises at
once. Worktrees live under the `exec-*` namespace: `shared_clean` jobs share one reused
`exec-clean` worktree; each `exclusive` card gets its own `exec-<ref>` worktree, created on
demand and torn down when its run terminates. The remaining keys are optional: `cache_dir` is a
warm dep/build cache passed to the prepare hook, `prepare` is that hook's path, and
`max_retained_failed` caps how many failed-run worktrees are kept on disk for post-mortem.

> [!WARNING]
> **Running more than one `exclusive` slot?** Concurrent runs each work in their own worktree,
> so make sure they don't share mutable state — most importantly, **give each run its own test
> database** (or equivalent) so parallel test suites don't truncate each other. How you do that
> depends on your project's toolchain.

**Cancel/revoke.** If a run is cancelled server-side while this executor is running one of its
jobs, the executor terminates that job's subprocess on its next heartbeat. An `exclusive` job's
worktree is reset; a `shared_clean` job's is left as-is (it is shared by other jobs that may
still be running there). Either way, no outcome is reported for a revoked job.

## The node contract

You only need this if you **author your own flows or agents**. Using the shipped flows, Relay
handles all of it. The server hands the executor one node-job at a time; the executor runs it in
the card's worktree and reports a typed **outcome** that routes the card to the next node.
Everything a node needs arrives in the job (the card `ref`, the resolved `vars`, and — for an
agent node — which agent to run); nothing durable is passed through the working tree.

### Declaring an outcome

An agent node **must declare its verdict** by running:

```
relay outcome <succeeded|failed> [--detail TEXT|@file]
```

`detail` becomes the context handed to the next node. The rule is strict on purpose:

- **Silence is failure.** An agent that exits without declaring an outcome is reported
  `failed`, whatever its exit code — an agent that did nothing is indistinguishable from one
  that exited early, so it must never route past its own gate.
- **A success claim must be backed by a commit.** For the commit-producing Code nodes
  (`implement`, `final_fix`, `smoke_fix`, `acceptance_fix`), a `succeeded` that leaves the
  branch unchanged is overridden to `failed`.
- **Asking a human always wins.** If the node moved the card to `needs_input`, that is the
  outcome even if the node also declared something else.

The outcome-declaration reminder is appended to every agent node's prompt automatically, so the
requirement travels with every invocation. Shell and gate nodes are exempt — their exit code is
already an unambiguous verdict.

### `RELAY_NODE_SCRATCH`

Before running **every** node the executor sets `RELAY_NODE_SCRATCH` to a git-ignored temp file
inside the node's own worktree. It is **one file per card per node** — the path derives from
`(ref, node)`, so it is stable across retries and never collides with another run. Use it for
`outcome failed --detail @$RELAY_NODE_SCRATCH`, and put any sibling payload (e.g. a
`--questions` file for `needs-input`) next to it: `$(dirname "$RELAY_NODE_SCRATCH")/<name>.json`.
**Never invent your own absolute scratch path** — the per-`(ref, node)` namespacing is exactly
what stops two runs reading or clobbering each other's files.

### `RELAY_PLAN`

The executor also exports `RELAY_PLAN` to a plan file inside the node's worktree. Unlike
`RELAY_NODE_SCRATCH` it is **per-card, not per-node**: the Code flow's first node writes the
card's plan there, and every later node (`implement`, the reviewers, smoke/acceptance) reads the
same file. It is git-ignored and namespaced by card, so two runs' plans are always different
files. A node with no plan sees `RELAY_PLAN` unset, never inherited.

### Needs-input re-entry

A `needs_input` outcome parks the run. When the human clears the card and the run resumes, the
server hands the **same node** back and the agent's prior session is resumed with its context
intact — it picks the conversation back up rather than starting the node over.

## Operating invariants

If you build your own runner or agents, honor these — break one and cards corrupt each other's
work:

1. **One agent per working directory at a time.** A `git checkout` (or branch/file edit) is
   global to the directory — two agents on two branches in one directory overwrite each other.
   Serialize (one card at a time), or give each agent its own clone or `git worktree`. Don't run
   the runner and an interactive session in the same working tree at once.
2. **State lives on the board, never in the working tree.** Many cards are in flight, moving back
   and forth between stages; a card may be specced now and planned days later while others pass
   through. Nothing durable may depend on what's currently checked out or a shared repo-root
   scratch file.
3. **Each card owns its branch — check it out at the start of a step, commit at the end.** Every
   step must be self-contained: begin by checking out the card's branch (from its `branch`
   field), end by committing (never leave uncommitted changes for the next card to inherit).
4. **Work travels with the card.** The spec is the card's `description`; the acceptance criteria
   its `acceptance_criteria`; the plan its `plan` field. Materialize these into the branch
   just-in-time (at the per-card `$RELAY_PLAN` path), never via a shared file another card would
   clobber.
5. **Readiness is positional and prioritized.** A card is ready when the column immediately to
   its right is an AI column. Work right-to-left (finish what's furthest along first), respect
   WIP limits (don't pull into a full AI column), and skip blocked (`needs_input`) cards.
6. **Finish a stage by pushing to the next column — Review if it exists, else Done.** A `*:Review`
   substage is a human checkpoint (the runner stops; a human approves it into `*:Done`); a
   `*:Done` substage auto-continues. The board's substage layout *is* the checkpoint config.
7. **On failure, flag the card — never retry-loop.** Set the card to `needs_input` with the
   reason. Because blocked cards are skipped (invariant 5), a flagged card waits for a human
   instead of looping. Idempotent, no infinite loops.
8. **Ask, don't guess.** If a reasoning step needs clarification it calls `bin/relay needs-input`
   and stops; the human answers in the drawer; the card unblocks and resumes on a later tick.

For driving a card by hand — the CLI verbs, statuses, and the board vocabulary — see the
scaffolded `relay.md` and the rest of the docs at `/docs`.
