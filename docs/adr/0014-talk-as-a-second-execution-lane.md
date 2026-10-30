# ADR 0014 — Talk: a person-driven execution lane

## Status

Accepted

## Context

**Talk** is a terminal session on a card: a person opens the drawer's Talk tab (or presses `t`),
types, and a Claude Code session answers against that card's working tree. It is not a drawer
feature. It is a second way for an agent to run against a card, sharing the flow engine's
runners, worktrees and model usage.

The flow engine already has the machinery to run an agent somewhere else. Work is brokered as
`node_jobs` rows over the long-poll claim (`POST /api/node-jobs/claim`), which carries claim
pinning, revocation and the runner version floor. The server never holds an agent session: the
runner runs `claude -p`, captures the session id off the stream-json output, and reports it
back; the server stores only the id, and passing it as `--resume` is what continues a session.
That session lives in one machine's `~/.claude`, and a card's worktree lives on one machine's
disk.

Talk breaks assumptions every node job relies on:

- A node job is dispatched by a flow. A talk turn is dispatched by **a person typing**, at any
  time, on a card in any stage, including one an agent is working right now.
- A node job's session is disposable. A talk turn **continues** the previous one, so its
  session id is durable state tied to one machine.
- A node job owns its worktree while it runs. A talk turn wants that same tree, at the same
  time, and must not corrupt it.
- A node job's output may be dropped: the board-log path (`LogForwarder` → `Hamaca.AgentLog`)
  is best-effort by construction. A conversation is a record the person reads back, and lines
  missing from it are a lie.

The constraint is that Talk must not **corrupt** flow execution: the working tree and the card's
data stay coherent. It is allowed to **contend** with it for runners, worktrees and model usage.
A person asking a question may slow the pipeline down, and that is an accepted trade.

## Decision

**A talk turn is a node job with `kind: :talk` and no run.** It rides the existing dispatch
pipeline — the same claim, long-poll, pin, revocation and version floor — instead of a parallel
one. `run_id` is nil and no `Run` is synthesised: a Run would make every card with an open
conversation read as a card with an active run, and corrupt scheduling, flow metrics and the
baton. The kinds are the closed set `Schemas.NodeJob.kinds/0` (`flow_kinds/0`, `talk_kind/0`),
and every query over `node_jobs` that means "the engine's jobs" filters on `flow_kinds/0`.

What is genuinely new is the **transcript**: the `Hamaca.Talk` context and its three tables,
`talk_sessions` (one per card), `talk_turns` (one per human message) and `talk_events` (one per
rendered line, append-only).

1. **The turn is the unit, and it has a Stop button.** A turn is `queued` when the person
   presses Enter, `claimed` when a runner takes it, and ends `done`, `stopped` or `failed`. A
   session has at most one turn in flight; a second message is refused until it ends, because
   two concurrent `--resume` calls on one session id corrupt it. While a turn is live the send
   control becomes **Stop**, which revokes the job through the same revocation path node jobs
   use, so the runner kills the running `claude -p`. A stopped turn is a normal, non-error end:
   its partial output stays in the transcript. **Closing the drawer does not stop a turn** —
   detaching is not cancelling, and the output is waiting when the person comes back. A talk
   turn never parks the card: it never calls `Hamaca.Cards.request_input/3`, because parking
   blocks the card's flow.

2. **A card with live work is talked to in its own worktree; any other card, read-only in the
   shared clean checkout.** The server picks each turn's isolation when the turn is posted and
   sends it on the claim as `isolation`. A card has live per-card work when it has an active run
   of an `exclusive` flow, or any runner on the board holds its worktree (in any state,
   `retained` included):

   | The card's situation | Isolation | What the turn uses |
   | --- | --- | --- |
   | A node job holds the card's worktree | `exclusive` | Attach to it as it is — dirty, mid-edit. |
   | The card's last run failed and its tree was retained | `exclusive` | Reuse it as it is. |
   | A runner still holds a talk-created tree for the card | `exclusive` | Reuse it as it is. |
   | No live per-card work (run torn down, a `shared_clean` flow — every Spec/Plan card — or never run) | `shared_clean` | A shared slot in `<ns>-clean`, read-only (§5). |

   Reading the tree dirty is the point when there is one: it is what a second terminal on your
   own machine would see, and the work in progress is often exactly what is being asked about.
   When there is none, a clean checkout of the base branch answers the same questions without
   taking an exclusive slot, so a question never waits behind, or evicts, a Code run. A turn in
   `<ns>-clean` takes a `shared_clean` slot like any shared job and frees it when the turn ends,
   however it ends; the shared tree is never reset, re-baselined or checked out onto a branch
   for a turn, because other cards' jobs are running in it. An exclusive turn on a card with no
   tree (an older server, which sends no `isolation`) creates `<ns>-<ref>` on the card's branch,
   or the base branch if it has none. A talk-created tree is never torn down because a run
   ended — the session spans runs — and is retired like a failed run's leftover once it goes
   idle, so a card that was only ever talked to does not hold an exclusive slot forever. A turn
   that cannot be placed fails with a transcript line naming who holds the slots and what to
   change.

3. **A turn runs on the runner that holds the card's session.** The session records the
   runner that finished its last `done` turn as `pinned_runner_name`, and every later turn's job
   carries that pin, so only that runner can claim it. A turn is never served by a runner that
   does not hold the session: `--resume` elsewhere silently starts a *new* session behind the
   old scrollback, which is worse than an error. For the same reason the orphan reaper never
   requeues a talk job; a turn whose runner dies stays `claimed` until the person presses Stop.
   **The first turn is the exception, and it creates the pin**: a card with no session yet is
   claimable by any Talk-capable runner. An `exclusive` first turn bypasses the
   advertised-capacity filter, because refusing it on a busy runner would mean a card nobody has
   talked to can never be talked to; a `shared_clean` one needs a free shared slot and waits
   queued otherwise. The runner itself still refuses a turn it cannot place.
   **A pin to a gone runner is released.** The holder is gone when the board has no runner of
   that name, or it has been silent longer than both the exclusive reclaim window and its own
   stale threshold — the same rule that parks an exclusive run as `runner_gone`, so the two can
   never disagree. A merely stale holder keeps its pin. Releasing clears the pin *and* the
   session id together, so another runner is never handed `--resume` for a session on a
   different disk: the next turn is a fresh session on any runner, still seeded with the card's
   context, and that runner becomes the new holder. The pane says so in one transcript line.

4. **The transcript is a durable record, not a log.** Lines are ordered by a server-assigned
   `seq`, never a timestamp. The runner delivers them at least once, numbering each turn's
   lines with a `client_seq`, and a replayed line is dropped, so a retry can neither lose nor
   duplicate output. A malformed line is dropped on its own and never costs the batch. `/clear`
   hides scrollback and deletes nothing. The runner reports through its own two routes,
   `POST /api/talk/turns/:id/events` and `POST /api/talk/turns/:id/outcome`, because a talk
   job has no run for the node-job outcome route to finalise.

5. **Talk's prompt and permissions are product code, and Talk is read-only.** The runner
   builds the turn's prompt itself — a fixed preamble, the card's seed fields, then the
   person's text verbatim — and not from a `.claude/agents/*.md` definition. This is a
   deliberate exception to [ADR 0006](0006-workflow-orchestration.md), which gives repos
   ownership of node behaviour: Talk is a property of Hamaca and must behave the same on every
   connected repo. Talk always runs Claude Code, whatever harnesses the board routes flow nodes
   to. The preamble lets the agent read any file, run read-only commands and query the card
   through the CLI (`why`, `runs`, `card`), and tells it not to edit files, commit, push or
   change the card. In the shared clean checkout read-only is **enforced by the tools**: `claude`
   runs deny-by-default (`--permission-mode dontAsk`) with one read-only allowlist — reading and
   searching files, read-only `git`, and the three CLI queries — and `Edit`, `Write` and
   `NotebookEdit` disallowed, and its preamble says the tree is a clean base checkout, not the
   card's worktree. In the card's own worktree it runs with `--permission-mode auto`, not
   `--dangerously-skip-permissions`, so its classifier denies risky actions on its own; that
   stays until Talk can write.

6. **The baton does not move.** A talk turn does not change who holds the card. Ownership
   tracks who is responsible for the card's progress through its flow, not who touched it last,
   and a person asking a question has not handed the card to an agent. A talk job therefore
   never refreshes the card's `agent_heartbeat_at`.

Talk is for authenticated board members only; a public viewer gets no Talk surface. On a
read-only board the pane shows an existing transcript but sends, stops and clears nothing. The mechanics —
the claim payload, worktree occupancy, event mapping and delivery — are in
[`docs/architecture/runner.md`](../architecture/runner.md) (Talk turns),
[`state.md`](../architecture/state.md) (node-job kind, talk turn status),
[`domain.md`](../architecture/domain.md) (`Hamaca.Talk`) and
[`runtime.md`](../architecture/runtime.md) (the `card:<card_id>:talk` topic).

## Consequences

**Good.**

- Stop, claim long-polling, pinning and the version floor come from machinery every flow run
  already exercises; Talk added a `kind` branch, not a second dispatcher.
- Talk sees reality — the dirty tree, mid-edit — which is what makes "why is this stuck?"
  answerable at the moment someone asks it, including mid-run.
- The transcript cannot silently lose or reorder lines, which is the property a conversation
  needs and the board log deliberately does not have.

**Bad, or newly required.**

- Every query over `node_jobs` must be `kind`-aware. This is the main bug surface of reusing the
  table; the mitigation is the closed set on `Schemas.NodeJob` and never re-typing it.
- A node job and a talk turn can occupy one worktree at once, so the runner tracks occupancy
  per occupant and defers a teardown until the last occupant leaves. Getting that wrong
  destroys a person's uncommitted work; runner.md records the rules.
- Talk creates worktrees for cards the engine would never dispatch, and the runner's in-memory
  `talk` marker on those trees does not survive a runner restart (runner.md names the gap).
- A pre-Talk runner must never see a talk job, so talk claims are gated on
  `Hamaca.Runs.min_runner_version/0` (`talk_capable?/1`).
- A turn stranded on a dead runner needs a person to press Stop; nothing recovers it.
- In the card's own worktree, read-only rests on the prompt and the auto-mode classifier, not
  on a tool restriction; only a turn in the shared clean checkout is tool-restricted. Talk
  cannot change the card or steer the agent working it; steering a running node is the Detail
  tab's *Steer now*, and the pane points there.
- A card that switches isolation between turns (a run starts, or its tree is released) starts a
  fresh `claude` session, because a session lives under one tree's directory. The pane says so.
- Talk and flow runs draw on the same model usage, so a busy conversation can slow the pipeline.
  Accepted deliberately.

**Kept in sync.** `docs/architecture/runner.md`, `state.md`, `domain.md` and `runtime.md` (see
the Decision), and the talk claim payload in the runner contract fixture.

## Alternatives considered

**A parallel claim lane, endpoint and worker for Talk.** It would re-implement claim, long-poll,
pinning, revocation and the version floor, and cancellation is required, so that machinery is
not optional. Reusing `node_jobs` with a `kind` discriminator gets all of it, at the cost of
making every query over the table kind-aware.

**Synthesising a `Run` per turn.** Reuses even more, but every card with an open conversation
would read as having an active run, corrupting scheduling, metrics and the baton.

**Talk always in its own clean checkout.** Avoids two processes in one tree, but hides the
uncommitted work in progress that is often exactly what is being asked about. Talk uses the
clean checkout only for a card that has no such work.

**Talk always in the card's own worktree.** What Talk first shipped with. A question about a
Spec or Plan card took an exclusive slot and created a worktree, so on a busy runner it waited
behind, or failed against, Code runs that genuinely needed the slots.

**Refusing Talk while a run is in flight.** A card that looks stuck mid-run is precisely when
someone wants to ask.

**A persistent `claude` process per session.** Lower per-turn latency, but it makes the runner a
session server, adds a second code path that must emit the same event stream, and dies with the
runner. One-shot `--resume` turns are the simpler shape until latency says otherwise.

**A repo-owned agent definition for Talk.** Putting the prompt in `.claude/agents/` would make
Talk behave differently per repo, or be missing entirely, and every onboarded repo would need it
seeded.

## Open questions

- **Should Talk be able to write?** Today it is read-only. Letting it edit, commit or push needs
  writes to serialize with node jobs on the shared worktree, and every change it makes to the
  card to be recorded as an audited fact rather than the agent's own account of it.
- **Session growth.** `--resume` on a long-lived session gets slower and costlier every turn,
  and nothing starts a fresh session.
