# Runtime: processes, topics, real-time flow

## Supervision tree

```mermaid
flowchart LR
    subgraph fly["Phoenix app (Fly)"]
        engine["Flow engine<br/>Relay.Flows / Relay.Runs"]
        db[("Postgres<br/>flows · runs · node outcomes")]
        board["Board UI (LiveView)<br/>live run state on the card"]
        engine --- db
        engine -- "PubSub run events" --> board
    end
    subgraph dev["Developer machine (or future cloud sandbox)"]
        exec["bin/relay executor<br/>(thin: claim job, run, report)"]
        agent["claude -p<br/>one agent node"]
        repo["project checkout + worktrees<br/>CLAUDE.md · .claude/skills · MCP<br/>(developer-owned)"]
        exec --> agent
        agent --- repo
    end
    engine -- "node-jobs" --> exec
    exec -- "output stream + typed outcome" --> engine
```

One flat `one_for_one` supervisor (`Relay.Supervisor`, started by `Relay.Application`):

| Child | Purpose |
| --- | --- |
| `RelayWeb.Telemetry` | telemetry metrics/poller |
| `Relay.Repo` | Ecto → Postgres |
| `DNSCluster` | Fly multi-node discovery (no-op locally) |
| `Phoenix.PubSub` (`Relay.PubSub`) | all topics below |
| `RelayWeb.ApiLog` | in-memory recent API request log for the admin page |
| `Relay.BoardWatch` | ETS owner for per-board version counters (RLY-12) |
| `Relay.RunnerPresence` | ETS owner for per-board runner heartbeat snapshots (RLY-141); 10-min sweep prunes runners silent >24h |
| `Relay.Runs.Capacity` | ETS owner for per-executor advertised free capacity (RLY-133); empty until W9 |
| `Registry` (`Relay.Runs.SchedulerRegistry`) | per-board scheduler lookup keys (RLY-133) |
| `Relay.Runs.SchedulerSupervisor` | DynamicSupervisor for per-board `Scheduler.Server`s (RLY-133); boot-starts per board only when `:runs_auto_start` |
| `Relay.Activity.LogSink` | debounces runner log lines into one `insert_all` per burst (RLY-112) |
| `Relay.Activity.Pruner` | ages `:action` chatter out after 14 days; first sweep one interval after boot |
| `Task.Supervisor` (`Relay.Push.TaskSupervisor`) | push dispatch off the caller's process (RLY-81) |
| `Finch` (`Relay.Push.APNSFinch`) | dedicated HTTP/2 pool — APNs requires h2; Req's default pool is h1-first |
| `Relay.Runs.Supervisor` | runs engine (RLY-132): run-id `Registry`, `DynamicSupervisor` with one transient `RunServer` per `:running` run, the card-event `Listener`, a boot task that resumes unfinished runs from Postgres (revokes orphaned jobs, re-dispatches the current node), and `Relay.Runs.ExecutorReaper` (RLY-134, inside this `rest_for_one` subtree). Not started in test. |
| `Relay.Runs.ExecutorReaper` | inside `Relay.Runs.Supervisor` — periodic (30s) sweep calling `Relay.Runs.reclaim_stale_executors/0`: requeues a dead executor's `shared_clean` jobs, parks its `exclusive` runs (`parked_reason: :executor_gone`). No new PubSub topic — the claim long-poll (`POST /api/node-jobs/claim`) reuses `board:<id>:runs` below. |
| `RelayWeb.Endpoint` | Bandit HTTP server, WebSockets |

## Session lifetime

The browser session is a signed cookie (`_relay_key`, no server-side record). Its policy is
**7 days, sliding** (RLY-127), and it lives in three places that must agree:

| Piece | Where | Role |
| --- | --- | --- |
| `RelayWeb.SessionPolicy` | `lib/relay_web/session_policy.ex` | the only copy of the numbers: `max_age/0` = 7 days, `refresh_after/0` = 1 day |
| `max_age` on `@session_options` | `lib/relay_web/endpoint.ex` | makes `_relay_key` persistent so it survives tab eviction / browser restart. Also reaches the LiveView socket via `connect_info` |
| `:session_refreshed_at` in the session | `RelayWeb.Auth` | the server-side window |

The cookie attribute is a **client-side hint only** — `Plug.Session.COOKIE.get/3` does no age
check, so a client can replay an arbitrarily old cookie. `RelayWeb.Auth` therefore enforces the
window itself:

- `fetch_current_scope/2` (the `:browser` pipeline) **expires** a session stamped past
  `max_age/0` and **re-stamps** one older than `refresh_after/0`. The re-stamp is a session
  write, and `Plug.Session` only emits `Set-Cookie` on a write — that is what slides the
  cookie's `Max-Age` forward. Throttling to once a day is what keeps `Set-Cookie` off every
  response.
- `mount_current_scope/2` (the `on_mount` hooks) **expires only** — a LiveView mount has no
  `conn` and cannot write a cookie. It closes the hole where a stale cookie mounts a LiveView
  on socket reconnect without passing through the plug pipeline.
- `NativeAuthController.me/2` **re-stamps** on success: the Flutter shell's launch-time verify
  is the native app's only touch point, and `_restore()` writes the refreshed cookie back to
  the Keychain.
- A session with **no** stamp (predating RLY-127) is re-stamped, never expired — expiring them
  would sign out every existing user on deploy.

There is no revocation: invalidating a session today means rotating `SECRET_KEY_BASE`, which
signs out everyone everywhere. Server-side session records and "sign out of all devices" are
tracked as a separate follow-up.

## PubSub topics

| Topic | Broadcaster | Events | Subscribers |
| --- | --- | --- | --- |
| `board:<board_id>` | `Relay.Events` — contexts only, after successful mutations | `{:card_upserted, card}`, `{:card_moved, card, from_stage_id}`, `{:card_archived, card}`, `{:timeline_appended, card_id, entry}`, `{:card_log_appended, card_id, entries}`, `{:stages_changed, board_id}`, `{:board_updated, board}` | every open `BoardLive` for that board |
| `board:<board_id>:logs` | `Relay.AgentLog` | `{:agent_log, entry}` — live runner feed lines | the board's log sheet, only while open (no backfill by design) |
| `board:<board_id>:runners` | `Relay.RunnerPresence` | `{:runner_beat, runner}` — a runner's latest heartbeat snapshot | `BoardRunnersLive` (which also refetches on its own ~10s tick, since a dead runner emits no events) |
| `board:<board_id>:runs` | `Relay.Runs` | `{:run_started, run}`, `{:node_started, run, execution}`, `{:node_finished, run, execution}`, `{:run_parked, run}`, `{:run_resumed, run}`, `{:run_finished, run}`, `{:run_changed, card_id}` | run UI (card 07/W8) and tests. Does NOT bump `BoardWatch`. The engine's fine-grained events above are internal; `{:run_changed, card_id}` (`Relay.Runs.broadcast_run_changed/2`, RLY-137) is the read side's coarse public contract — a subscriber refetches the card's runs/summary rather than patching state from a payload. |
| `events:firehose` | `Relay.Events` — mirrors every board event as `{board_id, event}` | every `board:<board_id>` event, tagged with its board id | `Relay.Runs.Listener` (reconciles card events against runs — RLY-132) |
| `runs:capacity` | `Relay.Runs.Capacity` | `{:executor_capacity_changed, executor_id}` — an executor's advertised free capacity changed | every per-board `Relay.Runs.Scheduler.Server` |
| `api_log` | `RelayWeb.ApiLog` | `{:api_log, entry}` | `Admin.ApiLive` |

Two invariants make the seam trustworthy: **only contexts broadcast** domain events (so
LiveView and REST mutations share one path), and broadcasting is **fire-and-forget** (a
PubSub failure can never fail the mutation). Every `Events.broadcast/2` also bumps the
board's `BoardWatch` version, which the CLI polls to avoid refetching unchanged boards.

## Load-bearing sequences

A card move fanning out to every open board (same path for REST and LiveView writers):

```mermaid
sequenceDiagram
    participant A as Agent (REST) or BoardLive (drag)
    participant C as Relay.Cards
    participant E as Relay.Events
    participant L as every BoardLive on board:id
    A->>C: move_card(scope, card, stage)
    C->>C: validate vs ADR 0003 rules, persist
    C->>E: broadcast {:card_moved, card, from}
    E-->>L: PubSub (fire-and-forget)
    E->>E: BoardWatch.bump(board_id)
    L->>L: re-stream card into new column
```

The needs-input round trip (the baton passing to a human and back):

```mermaid
sequenceDiagram
    participant R as runner step (claude -p)
    participant API as POST /api/cards/:ref/needs-input
    participant C as Relay.Cards
    participant H as human (BoardLive drawer)
    R->>API: questions JSON
    API->>C: needs_input(card, questions)
    C->>C: status → needs_input (card blocked)
    C-->>H: {:card_upserted} via Events
    H->>C: answer (drawer stepper)
    C->>C: status cleared, answer on timeline
    Note over R: runner sees the answer on its next scan and resumes the card
```

---
*Sources of truth: `lib/relay/application.ex`, `lib/relay/events.ex`,
`lib/relay/agent_log.ex`, `lib/relay/board_watch.ex`, `lib/relay/runner_presence.ex`,
`lib/relay_web/api_log.ex`, `lib/relay/runs.ex`, `lib/relay/runs/supervisor.ex`,
`lib/relay/runs/listener.ex`, `lib/relay/runs/executor_reaper.ex`, `lib/relay/runs/`.*
