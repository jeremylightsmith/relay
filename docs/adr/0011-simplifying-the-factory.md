# ADR 0011 — Simplifying the factory: the task is the unit of record

## Status

Proposed (2026-09-24)

<!-- The principles below are a proposal. The sequencing question is deliberately left open —
     see "Not yet decided". Nothing here is Accepted; do not treat it as settled. -->

## Context

Running the Code flow for real has surfaced three problems that feel like one problem — "the
factory is brittle and there's too much of it to hold in your head" — but are structurally
distinct and have different fixes. Separating them is most of the value of this ADR.

### 1. The plan is a document pretending to be a data structure

The card's `plan` field is markdown. The Code flow's `implement` node iterates
`card.sub_tasks`, and those sub_tasks are produced by running a **regex over that markdown**:
`Relay.Runs.PlanTasks` (30 lines) scans for `## Task N: <name>` headings and yields a list of
titles.

That contract has failed in production three times, each recorded in the module's own comments:

| Incident | Cause | Effect |
| --- | --- | --- |
| RLY-165 | parser demanded exactly three `#`; planner emitted two | parsed to `[]` |
| RLY-206 / RLY-209 | parser demanded a colon; planner emitted an em-dash | parsed to `[]` |

`[]` is not a benign outcome. Zero sub_tasks made the first `foreach` guard read
`:foreach_exhausted` — indistinguishable from "I finished the work" — which routed past every
implement lap to `precommit`, trivially green on an empty diff, then through review, smoke and
`merge`. An unparseable heading would have merged an empty branch as though the card were done.
`Relay.Runs.maybe_seed_sub_tasks/2` now refuses to start such a run (RLY-165), and
`lib/relay/runs/plan_tasks.ex` accepts two-to-four hashes and four separator characters. Both
are mitigations of a design choice, not fixes for it.

The choice ripples much further than the parser:

- **`code.json`'s `branch` node** carries
  `{relay} card {ref} --json | jq -r '.plan // empty' > "$RELAY_PLAN" && test -s "$RELAY_PLAN"`
  — a card field re-materialized as a file because downstream nodes can only consume prose.
- **`$RELAY_PLAN`** exists as an env-var contract solely to name that file. RLY-223 was a
  leak between runs through it.
- **`.claude/commands/write-plan.md`** spends roughly 35 of its 201 lines on heading
  punctuation, in bold, with the failure mode spelled out — prose compensating for a parser.
- **`.claude/agents/plan-implementer.md`** opens by telling the agent to resolve `$RELAY_PLAN`
  ("e.g. `echo $RELAY_PLAN`") and read that file.
- **`Consumes` / `Produces` blocks** are required in every task because "each task's
  implementer sees only its own task, so this block is how it learns the names and types its
  neighbors use." The engine already knows the sibling tasks; it cannot pass them, because
  tasks are not rows.
- **`## Verification` / `Gate:` / `Smoke:`** are lines of prose inside the plan that four
  different agents are told to parse by eye (`plan-implementer`, the whole-suite gate,
  `smoke-tester`, `acceptance-tester`). This is the "a magic value is defined exactly once"
  rule (`AGENTS.md`) being broken in prose.

Meanwhile `Schemas.SubTask` — the table that *is* the list of work — carries three fields:
`title`, `done`, `position`. The structure exists and holds almost nothing.

### 2. The Code flow is 22 nodes and 42 edges, and 8 nodes are one subgraph written twice

`docs/designs/flows/code.json` contains two near-identical verify blocks:

| First pass | Second pass | Difference |
| --- | --- | --- |
| `sync` | `resync` | none — byte-identical `run` |
| `sync_fix` | `resync_fix` | which gates must be green |
| `precommit` | `reverify` | none — both `mix precommit` |
| `browser` | `rebrowser` | none — both `mix test.browser` |

Both fix nodes name the same agent (`rebaser`); the only real difference is that `resync_fix`
must leave `mix precommit` **and** `mix test.browser` green while `sync_fix` needs only the
former. That is a parameter, not a node. Fabro solves this with **Imports** (reusing a workflow
as a subgraph inside another); Relay currently solves it with copy-paste, which means every
future change to the verify block must be made in two places and stay consistent by discipline.

The same pressure shows elsewhere: `spec_review` and `quality_review` are two nodes, two agent
files, and two model tiers for what a reader experiences as "review this task."

### 3. A node author must hold about twelve contracts in their head

To author or debug one node, the current surface is: the outcome triple
(`succeeded | failed` + detail + `--no-changes`); `$RELAY_NODE_SCRATCH` **and** the
"sibling payload beside it via `dirname`" rule; `$RELAY_PLAN`; the `needs-input` questions-JSON
shape; `expects_commits` (and that the **server** may rewrite a declared `succeeded` to
`failed`); `foreach: card.sub_tasks` (the only accepted value); isolation classes
(`shared_clean` / `exclusive`) and runner affinity; `max_retries` vs `max_loops`; the declared
`writes` contract (a blank declared field rewrites `succeeded` to `failed`); `{placeholder}`
rendering — **and** that agent `.md` files are *not* passed through the renderer, so a
placeholder written there reaches the model literally.

The factory that encodes all this is 2,692 lines: 9 agents, 13 skills, 3 commands. The
questions-JSON heredoc alone is hand-written in four separate files.

**The fix pattern has already been found here, and applied twice.** `./relay`'s
`OUTCOME_CONTRACT` and `FINDINGS_CONTRACT` are appended to every agent prompt by the runner, and
the code comment states the principle exactly: *"every agent node, every flow, every repo, and
nothing for a flow author to remember."* RE251 was the bug that forced it — the engine had always
computed findings and shipped them in the payload, but substitution only fires for placeholders a
template *contains*, and no shipped node contained `{findings}`, so **every fix node in the
system was told to fix findings it was never handed.** That is the archetype: a contract an
author must remember is a contract that will be forgotten.

### What other factories do

| System | Unit of work | How it's stored |
| --- | --- | --- |
| [Fabro](https://docs.fabro.sh/execution/context) | node output | typed JSON against a declared schema, merged into a run-scoped key-value **context**; >100KB spills to a content-addressed blob; `for_each` reads *a flat context key* (an array) |
| [Task Master](https://github.com/eyaltoledano/claude-task-master/blob/main/docs/task-structure.md) | task / subtask | `tasks.json` with **stable ids**, dependencies, priorities, testStrategy — explicitly so "agents, humans, and your PRD all reference the same work" |
| [Kiro](https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html) | task | `tasks.md`, each task traced to a numbered requirement, **run one at a time with per-task review in the UI** |
| [BMAD](https://www.augmentcode.com/guides/bmad-method-ai-development) | story | monolithic PRD **sharded** into atomic self-contained story files, each carrying rationale, constraints and embedded tests so the Dev agent needs nothing else |
| [Spec Kit](https://github.github.com/spec-kit/quickstart.html) | task | `tasks.md`; reads checkbox state as a gate but **refuses to write it** |

Two findings, and the second one matters as much as the first:

1. **Everyone who got this working made the task the unit of record.** The only system still
   parsing a shared document is Spec Kit, which sidesteps the write problem by declining to
   write. Relay writes (`- [ ]` → `- [x]`), so it cannot sidestep it.
2. **High per-task fidelity is not what the others gave up.** BMAD's shards carry full
   rationale, constraints and embedded tests *per story*; Task Master carries a testStrategy
   per task. Sharding is about **addressability, not brevity** — which matters here, because
   Relay already tried low-fidelity plans and reverted (see Constraints).

Fabro is worth reading and worth **not** copying wholesale: it validates the product thesis
(ADR 0006 already credits it) but it is *larger* than Relay — roughly 100 documentation pages,
its own agent loop. The three ideas to take are typed structured output, context-as-data, and
subgraph composition. The thing to decline is its size.

### Constraints that bound any change here

- **ADR 0006** stands: Relay owns the graph, the developer owns node behavior, and an agent node
  stays one `claude -p` invocation. Nothing here crosses into owning the agent loop.
- **ADR 0001** stands: no parallel client or API surface.
- **Plan fidelity is a settled question.** Contract-only plans (intent + signatures, no code)
  were tried and reverted in favour of plans carrying full code and tests. This ADR is about
  **where** per-task detail lives, not **how much** of it there is. Anyone reading this as
  licence to thin the plans is reading it wrong; that would need its own ADR and its own
  evidence.
- **`AGENTS.md`'s "a magic value is defined exactly once"** is the rule this ADR extends from
  code into the factory's prose and flow documents.
- Anything mirrored across the wire into `./relay` must stay pinned by
  `test/fixtures/runner_contract.json`, and any change to `./relay` bumps `RUNNER_VERSION`.

## Decision

Three principles, proposed:

**1. The task is the unit of record.** Per-task detail lives in `sub_tasks` rows, not in headings
inside a markdown blob. `/write-plan` writes them structurally (e.g.
`./relay tasks <ref> @tasks.json`); the engine hands the implementer *its own row*, plus its
siblings' declared outputs. The card's `plan` field survives as the header — Goal, Architecture,
Global Constraints — the parts that genuinely are prose. `Relay.Runs.PlanTasks`, `$RELAY_PLAN`,
the `branch` node's `jq` incantation and the heading-punctuation contract all cease to exist
rather than getting better mitigations.

*Sketch of the row, not a spec:* the fields the plan carries in prose today — intent, files
(create/modify/test), `consumes` / `produces`, steps with their code, gate, smoke, commit
message, plus a `findings` field a reviewer can write to so per-task review results attach to the
task instead of living only in a loop-back prompt. Fidelity per task is unchanged (see
Constraints); it becomes addressable, which is the whole point.

**2. The runner owns the contract; the author owns the prompt.** Every remaining "remember this"
becomes something the runner appends or the CLI constructs — extending the pattern
`OUTCOME_CONTRACT` and `FINDINGS_CONTRACT` already established. Concretely: a
`./relay ask "<question>" --option … --option …` verb that builds the questions JSON, so the
heredoc disappears from all four files that hand-write it, and the CLI owns its own scratch path
so `$RELAY_NODE_SCRATCH` and its `dirname` rule leave the author's mental model entirely. The
target is that authoring a node requires knowing one thing: it receives a prompt and returns
succeeded, failed, or a question.

**3. A flow's graph is composed, not copy-pasted.** The duplicated verify block becomes one
parameterized subgraph (Fabro's Imports idea, in Relay's declarative-document form). Twenty-two
nodes should read as about fourteen, and `spec_review` + `quality_review` should be one review
node with two dimensions.

### Not yet decided

**The sequencing is an open decision, and this ADR does not make it.** Three shapes were on the
table (full write-ups in Alternatives considered):

- **A first** — tasks as rows. The structural fix; closes whole bug classes; larger branch.
- **B first** — collapse the surface. Nearly all subtraction; lands fast; no new capability.
- **Both as one design** — most coherent end state; largest single branch; hardest to land.

The recommendation on the table is **B then A**: B is cheap and mostly deletion, it directly
addresses the "can't hold it in my head" complaint, and A is easier to land against a 14-node
flow than a 22-node one.

Questions that need answers before A can be designed:

1. **How does a human repair a broken task?** Today a plan is one markdown textarea — a human
   can fix anything in it in ten seconds. Rows need an editing surface (drawer panel, Storybook
   story, the lot) or A makes the system *less* human-recoverable than it is now. This is the
   central design question of A, not a detail.
2. **Do review findings live on the task row?** Attractive (findings survive the run, and a
   loop-back stops being the only channel) but it widens the schema and the `writes` contract.
3. **Does `foreach` stay `card.sub_tasks`-only, or become a general "iterate a card field that
   is a list"?** The narrow version is honest about what exists; the general version is closer
   to Fabro's `for_each` over a context key.
4. **Where does `Gate:` / `Smoke:` land** — per task row, per card, or per flow? It is currently
   parsed by eye out of plan prose by four agents, so anywhere named beats today.
5. **Does the `plan` field keep its `- [ ]` checkboxes at all** once rows own done-state? Two
   representations of done-state is precisely the duplication this ADR objects to.

## Consequences

**Good**

- Three recorded failure classes (RLY-165, RLY-206/209) become impossible rather than mitigated,
  and the "empty plan merges an empty branch" hazard loses its mechanism.
- `PlanTasks`, `$RELAY_PLAN`, the `branch` node's `jq` pipeline and the heading contract are
  deleted, not documented better. Roughly 60 lines of prose across `write-plan.md` and
  `plan-implementer.md` go with them.
- `Consumes` / `Produces` stops being an authoring burden — the engine has the sibling rows and
  can pass them.
- The Code flow becomes readable on one screen, and the verify block has one definition.
- A newcomer's required knowledge drops from ~12 contracts to roughly one.

**Bad, and to be planned for**

- A schema migration plus an editing surface for task rows; without the latter, human recovery
  regresses (open question 1).
- `./relay` changes mean a `RUNNER_VERSION` bump, a `runner_contract.json` re-pin, and a
  judgement call on `Relay.Runs.min_runner_version/0`.
- In-flight cards straddle the change. Flows are versioned and a run snapshots its version, which
  covers the graph — but a card whose `plan` was written under the old shape needs either a
  migration or a tolerated read path.
- `docs/architecture/` pages, `relay.md`, and the hosted `/docs` CLI/API pages all describe the
  current contract and must move in the same branch (`AGENTS.md`'s freshness gate).
- Merging `spec_review` and `quality_review` loses the per-dimension cost/verdict split that
  `./relay flow-stats` currently reports. Check the numbers before collapsing them.
- Every `.claude/agents/*.md` touched means `/relay-doctor` must be re-run by hand.

## Alternatives considered

**A — Tasks become rows; the plan becomes a header.** The structural fix described in the
Decision. Wins on durability: it removes mechanisms rather than adding guards, and it is what
every comparable system converged on. Loses on cost — schema, migration, planner rewrite,
implementer rewrite, and a new editing surface — and it carries the unanswered
human-editability question.

**B — Collapse the surface.** Parameterize the duplicated verify subgraph, merge the two review
nodes, consolidate 9 agents toward ~5 (implement / review / fix / verify / ship), add
`./relay ask`, and let the CLI own its scratch path. Nearly all subtraction, so it is cheap and
low-risk, and it targets the onboarding complaint most directly. Loses on ambition: it makes the
current design legible without removing the parsed-document mechanism at its centre, so the bug
classes in Context §1 all survive it.

**C — One page.** "Relay in 10 minutes": a card has fields, a flow is nodes and edges, a node
gets a prompt and returns succeeded/failed/ask. Rejected as a standalone direction because it is
a **byproduct** of A and B rather than a peer to them — written against today's surface it would
be a 12-contract page, and no amount of good prose fixes that. Worth doing, right after.

**Do nothing.** Rejected, but named because it is the status quo's real argument: the mitigations
work, the flow does ship cards, and each individual contract is documented. What it does not
survive is the second developer. Every item in Context §3 is knowledge currently held by one
person and a 2,692-line factory, and the RE251 archetype — a contract every fix node forgot,
undetected across the whole system — is what that costs.
