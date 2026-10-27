# ADR 0006 — Workflow orchestration: Hamaca owns the graph, developers own the nodes

## Status

Accepted

## Context

Hamaca drives cards through AI work, and that work has to satisfy five forces at once:

1. **Visibility.** Per-node progress, verdicts, cost and logs belong on the card, live.
2. **Shared across projects.** The workflow ships with Hamaca. A new project needs
   near-zero setup, and a workflow improvement reaches every board.
3. **Gates enforced by the engine.** "Don't merge unless review passed" is a routing rule,
   not a sentence in a prompt. Outcomes are typed; retries, loops and resume are the engine's.
4. **Developers own their process.** A developer shapes how a node does its work (their
   `CLAUDE.md`, skills, subagents, MCP) in their own repo, without forking Hamaca, and can take
   the baton and work a card themselves (the claim rule, [ADR 0004](0004-card-ownership-and-the-claim-rule.md)).
5. **Execution locality.** Agent steps need the checkout, git worktrees and an agent CLI, which
   means a developer's machine; the app runs on Fly.

Forces 2 and 4 pull against each other: centralizing the workflow serves 2, developers owning
their skills serves 4. [Fabro](https://fabro.sh/) validates the thesis (a graph of agents,
shell steps and human gates projected onto a board) but owns its own agent loop and treats the
graph as the source of truth with the board derived from it. Hamaca is inverted: the board is
the graph, and humans move cards on it directly.

## Decision

**Hamaca owns orchestration; each node stays a black box the developer controls.**

1. **Own the flow, not the agent loop.** Hamaca sequences nodes, routes outcomes, counts
   retries and loops, enforces gates and runs fan-out. An agent node is one headless
   invocation of the node's agent CLI (a board *harness*: Claude Code, Codex, Gemini CLI),
   which keeps owning tools, permissions and context inside the node.

2. **The engine lives in the Phoenix app.** `Hamaca.Flows` holds flow definitions;
   `Hamaca.Runs` executes runs as supervised, Postgres-backed state machines, records every
   node execution (outcome, detail, git SHA, session, cost) and broadcasts on PubSub, so the
   board renders run state natively and a run resumes from durable state after a restart.
   Dispatch is server-side (`Hamaca.Runs.Scheduler`). The runner talks to it over the board-key
   REST API, extended with node-job endpoints: a deeper agent API, not a parallel client
   ([ADR 0001](0001-client-architecture.md)).

3. **`./hamaca` is the executor.** In `./hamaca start` mode it claims node-jobs, runs the agent
   CLI or shell command in a worktree, streams output up and reports a typed outcome. It holds
   no pipeline definition and no dispatch logic. A flow declares only the isolation a node needs
   (`shared_clean` or `exclusive`); each runner maps that onto its own worktrees and advertises
   its capacity (`.hamaca/runner.json`), so the server never knows a machine's filesystem.
   **Exclusive runs have runner affinity:** every job of the run goes to the runner holding its
   worktree, and if that runner disappears the run parks rather than moving.

4. **Flows are declarative graph data**, not DOT and not code: typed nodes, a closed outcome
   set, outcome-routed edges with loop budgets, per-node retries.

   | Node type | What it is |
   | --- | --- |
   | `agent` | one agent-CLI run in the checkout; may name a repo subagent (`agent`) and a board LLM (`llm`) |
   | `shell` | a command; exit code → `succeeded` / `failed` |
   | `gate` | a deterministic check (e.g. `mix precommit`) whose failure must reroute or fail the run |
   | `fan_out` / `fan_in` | control nodes the server resolves with no job: a fan-out region runs every branch, up to `max_parallel` at once, and joins wait-all, failing if any branch failed |
   | `human` | reserved; a flow containing one cannot start a run |

   Any node can be a `foreach` loop head; its one source is the card's tasks (`card.tasks`).
   Agents declare `succeeded`, `failed`, `partial` or `needs_input`. `needs_input` parks the run
   and blocks the card; the answer re-enters the same node, resuming its session where the
   harness can. The runner alone reports `blocked` (the CLI couldn't run: login or usage limit),
   which waits for a known reset or parks, before any edge is read. An outcome with no edge of
   its own degrades onto the node's `failed` edge; an unrouted `failed` fails the run.

   **Stages are places; flows are the AI work in them.** A flow names one stage, a stage holds at
   most one flow, and where the flow pulls from and lands on is worked out from board order
   (`Hamaca.Flows.neighbours/2`). A stage is AI-enabled iff a flow is on it. The review gate is a
   human action *between* flows; a deterministic check is a `gate` *inside* one. Re-entering a
   flow is always a human gesture (a rejection, a move): the engine never infers rework from a
   card going backwards.

   Every definition-changing save bumps the flow's version and keeps an immutable snapshot, but
   a run follows the live flow. Flows are edited on the board (Settings › Stages) or pushed whole
   from the repo (`./hamaca flow-push`, last write wins). New boards are seeded from the default
   library (`docs/designs/flows/`) or a board template (`docs/designs/templates/`).

5. **Developers own node behavior.** Agent nodes run in the project checkout, so the repo's
   `CLAUDE.md`, `.claude/skills/`, `.claude/agents/` and MCP config apply: editing a skill
   changes what the node does with no Hamaca change. A board may replace any flow outright.
   And the baton still passes: a human claiming a card mid-run revokes the active job and parks
   the run; handing it back resumes fresh.

6. **The card is the context bus.** Spec, plan, tasks and comments live on the card, and each
   node's prompt starts from it. Within a run there are two more channels: the shared worktree
   (the diff is the reviewers' context) and the previous node's outcome detail, which the engine
   passes on (`{prior_detail}`, and a findings block the runner appends on a loop-back). Each
   node starts a fresh agent session, so a reviewer judges the diff rather than inheriting the
   implementer's reasoning; `--resume` is used only when a node re-enters itself after
   `needs_input`.

7. **Fan-out branches share the run's one checkout** on its one runner. Concurrent edits are
   the flow author's responsibility; git fork-and-join isolation per branch is deferred to
   RE161 until a flow proves it needs it.

How the engine, scheduler, transport and runner work in detail:
[runner.md](../architecture/runner.md) (including
[fan-out regions](../architecture/runner.md#fan-out-regions-re437)),
[runtime.md](../architecture/runtime.md), [state.md](../architecture/state.md) and
[failures.md](../architecture/failures.md).

## Consequences

- Run state is data in Hamaca's database: live per-node visibility, cost and duration per node,
  resume after a crash, and gates the engine enforces.
- A new project gets a working pipeline by wiring the repo and starting a runner; a fix to a
  default flow reaches every board that hasn't replaced it.
- The server↔runner protocol (job claim, log streaming, heartbeat, reclaim) is ours to
  maintain, and anything mirrored across it is pinned by `test/fixtures/runner_contract.json`.
- Declarative flows are less expressive than code. Loops, fan-out and outcome routing cover the
  real flows; `shell` nodes are the escape hatch.
- A run pauses while its runner's machine sleeps, and an exclusive run waits for its own
  runner. A cloud runner would be a second implementation of the same protocol.
- Editing a flow can change in-flight runs, because runs follow the live definition.
- Talk turns are not flow nodes: their prompt is product code so Talk behaves the same on every
  repo ([runner.md](../architecture/runner.md#talk-turns-re268-adr-0009)).

## Alternatives considered

- **Keep exec-plan as a black box, ship skills as a plugin.** Solves sharing, but nothing for
  visibility, typed gates or harness quirks.
- **Grow the Python runner into the engine.** Builds the engine outside the product, invisible
  to the board except through log forwarding, and per machine instead of shared.
- **Own the agent loop too (full Fabro).** Means maintaining our own harness and abandoning the
  skills ecosystem developers already own, which breaks force 4.
- **DOT as the flow language.** Conditions live in string attributes and authoring is worse
  than data plus an editor. We keep rendering the graph, not the syntax.
- **Flows as per-project code.** Maximum expressiveness, but it *is* the setup and drift burden
  force 2 removes. Repo skills remain the way to customize a node.

## Open questions

- **Should a run pin the flow version it started on?** Snapshots exist (`flow_versions`), but
  runs read the live flow today.
- **Does the `human` node type get built, or go?** It validates in a flow but no run can start
  on a flow that contains one; parking on `needs_input` covers human input today.
