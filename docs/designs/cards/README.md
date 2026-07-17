# Proposed cards — ADR 0006 workflow orchestration

Card breakdown for [ADR 0006](../../adr/0006-workflow-orchestration.md). Cards live on the
board (refs below); these files are the source their descriptions were created from (sync
with `bin/relay describe REF @file`). **File numbers are stable ids; W-numbers are play
order** — reordered 2026-07-17 to be UI-first, so every visible surface lands as early as
its dependencies allow: watch it work, then configure it, then cut over.

Rhythm of the order: instruments first (W1–W2, buildable against today's runner), then
the flow data model with its UI right behind (W3–W4), the engine with its UI right behind
(W5–W7, run panel built against the engine's fake-executor stub), then the
protocol/executor pair (W8–W10), the cutovers (W11–W13), and the long tail.

| Play | Board | File | Card | Depends on (file #) |
| --- | --- | --- | --- | --- |
| W1 | RLY-148 | [17](17-card-activity.md) | Card activity: entry model, health strip, timeline | — (buildable now) |
| W2 | RLY-141 | [11](11-runners-view.md) | Runners view: who's running, and what's on each | — (v0 now; 03/04 upgrade it) |
| W3 | RLY-131 | [01](01-flows-domain.md) | Flows domain: flow definitions as data + default library | — |
| W4 | RLY-142 | [12](12-flows-ui.md) | Flows management UI (board settings tab) | 01 |
| W5 | RLY-132 | [02](02-runs-engine.md) | Runs engine: supervised state machine | 01 |
| W6 | RLY-137 | [07](07-run-visibility.md) | Run visibility on the card | 02 (stub); full acceptance with 06 |
| W7 | RLY-143 | [13](13-flow-editor.md) | Flow editor: edit flows on the board | 01, 02, 12 |
| W8 | RLY-133 | [03](03-scheduler.md) | Scheduler: server-side dispatch | 01, 02 |
| W9 | RLY-134 | [04](04-node-jobs-api.md) | Node-job API: server↔executor protocol | 02 |
| W10 | RLY-135 | [05](05-executor.md) | `bin/relay` executor mode | 04 |
| W11 | RLY-136 | [06](06-spec-flow.md) | Spec flow end-to-end (first vertical slice) | 02, 03, 04, 05 |
| W12 | RLY-138 | [08](08-plan-flow.md) | Migrate the Plan flow | 06 |
| W13 | RLY-139 | [09](09-code-flow.md) | Decompose the Code flow (retire /exec-plan) | 06, 07 |
| W14 | RLY-140 | [10](10-project-overrides.md) | Per-project flow overrides | 06 |
| W15 | RLY-146 | [15](15-value-stream-map.md) | Value stream map | 17 |
| W16 | RLY-147 | [16](16-reopen.md) | Reopen: the default rework gesture | — |
| W17 | RLY-149 | [18](18-sub-cards.md) | Sub-cards: decomposition and bigger rework | 16 settles the model |
| W18 | RLY-144 | [14](14-phase-lanes.md) | Code column phase lanes (experiment) | 06, 07 — no artboard; check VSM first |

Done and off the board: [00](00-architecture-docs.md) living architecture docs (shipped
2026-07-16).
