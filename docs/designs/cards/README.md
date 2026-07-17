# Proposed cards — ADR 0006 workflow orchestration

Draft card breakdown for [ADR 0006](../../adr/0006-workflow-orchestration.md). Not on the
board yet — review here first, then create the keepers with `bin/relay create`.

Ordering follows the ADR's de-risking sequence: prove the whole architecture end-to-end on
the trivial Spec flow (01–06), make it visible (07), then migrate Plan (08) and decompose
Code last (09). 00 stands alone and can go first; 10 can land any time after 06.

| # | Card | Depends on |
| --- | --- | --- |
| [00](00-architecture-docs.md) | Living architecture docs: `docs/architecture/` + freshness gates | — |
| [01](01-flows-domain.md) | Flows domain: flow definitions as data + default library | — |
| [02](02-runs-engine.md) | Runs engine: execute a flow as a supervised state machine | 01 |
| [03](03-scheduler.md) | Scheduler: server-side dispatch (`find_all_ready` moves home) | 01, 02 |
| [04](04-node-jobs-api.md) | Node-job API: the server↔executor protocol | 02 |
| [05](05-executor.md) | `bin/relay` executor mode | 04 |
| [06](06-spec-flow.md) | Spec flow end-to-end (first vertical slice) | 02, 03, 04, 05 |
| [07](07-run-visibility.md) | Run visibility on the card | 06 |
| [08](08-plan-flow.md) | Migrate the Plan flow | 06 |
| [09](09-code-flow.md) | Decompose the Code flow (retire the /exec-plan black box) | 06, 07 |
| [10](10-project-overrides.md) | Per-project flow overrides | 06 |
