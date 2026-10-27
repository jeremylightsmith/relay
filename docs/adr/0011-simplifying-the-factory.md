# ADR 0011 — Simplifying the factory: the task is the unit of record

## Status

Accepted

## Context

The Code flow works a card one task at a time: its `implement` node is a `foreach` loop head
over the card's tasks, and each lap is reviewed, fixed and checked off on its own. So the list
of tasks is a data structure the engine iterates, addresses by id and records progress against.

When that list is produced by parsing prose, the parse is a contract nobody can see. A regex
over `## Task N: <name>` headings in the card's markdown `plan` broke in production more than
once (a heading level, a dash instead of a colon) and yielded zero tasks. Zero tasks reads as
"the loop is finished", which would route an empty branch past every implement lap, through
gates that are trivially green on an empty diff, to `merge`.

Every comparable factory (Task Master, Kiro, BMAD's story shards) made the task the stored,
addressable unit for the same reason; the one that still keeps a shared document (Spec Kit)
avoids the problem by never writing to it. Hamaca writes done-state, so it can't.

Bounds on any answer:

- [ADR 0006](0006-workflow-orchestration.md): Hamaca owns the graph, the developer owns node
  behavior, and an agent node stays one agent-CLI invocation.
- [ADR 0001](0001-client-architecture.md) / [ADR 0005](0005-mobile-app-scope-and-architecture.md):
  agents use the board-key `/api`; the only non-agent API is ADR 0005's native API (`/api/all` and `/api/auth/native`).
- `AGENTS.md`'s rule that a magic value is defined exactly once applies to the factory's prose
  and flow documents too.

## Decision

**A card's tasks are rows, and the plan is only their header.**

- Each task is a `Schemas.SubTask` row on the card: a `title`, a markdown `body` that is the
  task's whole spec, `done`, and a `position`. `Hamaca.Cards` owns them (`list_tasks/1`,
  `get_task/2`, `add_tasks/2`, `update_task/3`, `delete_task/2`, `set_sub_task_done/3`), exposed
  at `/api/cards/:ref/tasks` and in the CLI as `./hamaca tasks add|list` and
  `./hamaca task show|update|rm`.
- `/write-plan` writes the card's `plan` field as a **header** holding only what every task
  needs (Goal, Architecture, Tech, Global Constraints, and a `## Verification` block with the
  card's `Gate:` and `Smoke:`), then adds the tasks with `./hamaca tasks add`. Done-state lives
  on the rows only.
- `foreach` has exactly one source, `card.tasks` (`Schemas.Flow.Node.foreach_sources/0`). Nodes
  inside the loop name the bound task by `{task}` and `{task_id}`, and the implementer fetches
  its own body with `./hamaca task show <ref> <id>`.
- A run that iterates tasks never starts on zero: if the card has no tasks and none can be
  produced, the run is refused and the card blocked, so "loop finished" can only mean the work
  is done.

How much a task body carries is `/write-plan`'s concern
([`.claude/commands/write-plan.md`](../../.claude/commands/write-plan.md)): today, the
contract (signatures, schemas, `Consumes` / `Produces`) and behavior scenarios, not code.

## Consequences

- A task is addressable: the drawer shows which one is in flight with its body and history, a
  reviewer's verdict scopes to one iteration, and a human or agent can fix one task without
  touching the rest.
- Repairing a task's text is a CLI or API action; the drawer only toggles done.
- Legacy read path: a card with a `plan` but no task rows is still parsed into tasks at run start
  (`Hamaca.Runs.PlanTasks`), with a deprecation warning, `runs.tasks_from_plan` set, and the
  board audit's `planner_not_migrated` finding. It goes when that finding stays empty.
- The runner still materializes the header as a file per run (`$HAMACA_PLAN`, also exported as
  `$RELAY_PLAN`), written by the Code flow's `branch` node, and the `## Verification` lines are
  read by eye by four agents (`plan-implementer`, the gates, `smoke-tester`,
  `acceptance-tester`).
- `Consumes` / `Produces` are still authored in each body: the engine doesn't hand an
  implementer its siblings' rows.

## Alternatives considered

- **Keep the document, harden the parser.** Each fix widened the regex and the planner's prose
  rules. It mitigates the bug class; it can't remove it.
- **Collapse the factory's surface first** (merge the two review nodes, parameterize the
  duplicated verify block, fewer agents). Cheaper and mostly deletion, but it leaves the parsed
  document at the centre, so the bug class survives. Still worth doing; see below.

## Open questions

- **Should the runner own the remaining node-author contracts?** The outcome and findings
  blocks are already appended by the runner to every agent prompt. The needs-input questions
  JSON is still a heredoc written into prompts, beside `$HAMACA_NODE_SCRATCH` by a `dirname`
  rule; a `./hamaca ask` verb would make it the CLI's job.
- **Should the Code flow's verify block be one subgraph?** `sync` / `resync`, `sync_fix` /
  `resync_fix`, `precommit` / `reverify` and `browser` / `rebrowser` are written twice in
  `code.json`, and `spec_review` / `quality_review` are two nodes. Merging the reviews loses the
  per-dimension split `./hamaca flow-stats` reports.
- **Do review findings live on the task row?** Today they travel only in the loop-back prompt.
- **Should a human be able to edit a task's body in the drawer?**
