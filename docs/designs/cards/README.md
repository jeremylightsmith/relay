# Proposed cards — ADR 0006 workflow orchestration

Card breakdown for [ADR 0006](../../adr/0006-workflow-orchestration.md). Cards 01–11 are
on the board as RLY-131…141, titled `W1`…`W11` in play order; these files are the source
the board descriptions were created from (sync with `bin/relay describe REF @file`).

Ordering follows the ADR's de-risking sequence: prove the whole architecture end-to-end on
the trivial Spec flow (01–06), make it visible (07), then migrate Plan (08) and decompose
Code last (09). 00 stands alone and can go first; 10 can land any time after 06. 11 is
deliberately early — it's the debugging instrument for the rest, works against today's
runner, and upgrades its data source when 04/05 land.

| # | Card | Depends on |
| --- | --- | --- |
| [00](00-architecture-docs.md) | Living architecture docs: `docs/architecture/` + freshness gates | — |
| RLY-131 W2 · [01](01-flows-domain.md) | Flows domain: flow definitions as data + default library | — |
| RLY-132 W3 · [02](02-runs-engine.md) | Runs engine: execute a flow as a supervised state machine | 01 |
| RLY-133 W4 · [03](03-scheduler.md) | Scheduler: server-side dispatch (`find_all_ready` moves home) | 01, 02 |
| RLY-134 W5 · [04](04-node-jobs-api.md) | Node-job API: the server↔executor protocol | 02 |
| RLY-135 W6 · [05](05-executor.md) | `bin/relay` executor mode | 04 |
| RLY-136 W7 · [06](06-spec-flow.md) | Spec flow end-to-end (first vertical slice) | 02, 03, 04, 05 |
| RLY-137 W8 · [07](07-run-visibility.md) | Run visibility on the card | 06 |
| RLY-138 W9 · [08](08-plan-flow.md) | Migrate the Plan flow | 06 |
| RLY-139 W10 · [09](09-code-flow.md) | Decompose the Code flow (retire the /exec-plan black box) | 06, 07 |
| RLY-140 W11 · [10](10-project-overrides.md) | Per-project flow overrides | 06 |
| RLY-141 W1 · [11](11-runners-view.md) | Runners view: who's running, and what's on each | — (v0 now; 04/05 upgrade it) |
