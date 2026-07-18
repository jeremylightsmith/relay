# Runbook: cutting a stage over to an engine-driven flow

Moves one pipeline stage (`<Stage>`) off the legacy `relay watch` dispatcher and onto the
server-side scheduler + node-job engine (ADR 0006). Written once; W11 cut over **Spec**, W12
cuts over **Plan**, W13 cuts over **Code** — substitute `<Stage>` and its `relay_config.json`
entry throughout.

## Why the order is not negotiable

Two dispatchers must never pull the same cards. The watcher loads `relay_config.json` **once at
startup** (`load_config()` at `bin/relay:566`, called from `cmd_watch`), so removing a stage from
the file without restarting the watcher leaves it still pulling that stage. And the server-side
flow is inert until deployed. So:

- **Enabling the flow server-side before restarting the watcher** → both dispatchers on the same
  cards (double dispatch — the exact failure this ritual prevents).
- **Restarting the watcher before the deploy is live** → a stage nothing works.

## The ritual (in order)

1. **Merge and deploy.** The flow definition and any engine fix must be live server-side before
   anything else changes. Confirm the deploy is healthy.
2. **On the runner machine: pull ROOT, then restart `relay watch`** — with `<Stage>`'s entry
   already removed from `relay_config.json` (that removal ships in the same PR). The restart is
   what makes the watcher forget the stage; the file edit alone does nothing until restart.
3. **Only now, enable the flow** in the board's **Settings › Flows** (RLY-142's toggle, which
   already shows the double-dispatch warning dialog). No CLI or mix task — the UI toggle is the
   only enable path.
4. **Start / confirm `relay execute`** is connected and advertising capacity for the flow's
   isolation class (`shared_clean` for Spec/Plan, `exclusive` for Code).

   **Prerequisite this step depends on, not yet shipped by any binary:** `Relay.Runs.Capacity`
   (what the scheduler reads to decide whether to dispatch) is fed from exactly one place — the
   `name` + `capacity` branch of `POST /api/board/heartbeat`
   (`RelayWeb.Api.BoardController.heartbeat/2`, `maybe_advertise_executor/2`). `relay execute`'s
   own heartbeat posts to `/api/node-jobs/heartbeat` instead, with `{"executor", "running"}` only
   — it never hits `/api/board/heartbeat` and never sends `name`/`capacity`. Until an
   executor-side sender for that route ships, **manually POST it yourself** before this step is
   considered done, e.g.:

   ```
   curl -X POST https://<board-host>/api/board/heartbeat \
     -H "Authorization: Bearer <board-key>" -H "Content-Type: application/json" \
     -d '{"name": "<executor-name>", "capacity": {"shared_clean": <n>, "exclusive": <n>}}'
   ```

   Send the executor's **configured** total (the `capacity` you intend it to run, i.e.
   `cfg["capacity"]`) — not `ExecutorPool.capacity()`'s live free count. The scheduler already
   debits in-flight `:running` runs from the advertised total itself
   (`Scheduler.Server.build_snapshot/1`); posting the already-decremented free count here would
   double-debit every running run (see the TRAP comment at `board_controller.ex:57-61`).

   **If this beat is never sent, the ritual silently fails**: `Capacity.snapshot()` stays empty,
   the scheduler plans zero dispatches every tick, and `<Stage>` cards sit in *Next up* with no
   dispatcher at all — exactly the "a stage nothing works" failure this runbook exists to avoid,
   just one step later than the ordering hazard above.
5. **Confirm a card actually dispatches**: watch the first `<Stage>` card in *Next up* pick up a
   `Run` row (see Verification below) rather than sitting idle.

## Verification — "it worked"

- Exactly **one** dispatcher claims each `<Stage>` card (never both watch + engine).
- A `Run` row appears on the card (its run panel / timeline shows the node starting) within one
  scheduler tick of the capacity beat landing.
- **Not yet available:** the runners view (`/board/:slug/runners`) does **not** show the engine
  executor or its capacity — that page is backed by `Relay.RunnerPresence`, which only the legacy
  watcher's heartbeat populates (`runner_id` field); `relay execute` sends no `runner_id` to that
  route. Do not use the runners view to judge this cutover (tracked as B2, a follow-up). Use the
  card's run panel instead.

## Rollback

1. Disable the flow in **Settings › Flows**.
2. Restore `<Stage>`'s entry in `relay_config.json`.
3. Restart `relay watch` so it reloads the restored config.

**Not rolled back:** an in-flight run's `Run` / `NodeExecution` rows persist — cancel the run from
the card's run panel if you need it gone. Rolling back the flow does not retroactively unwind a
run already in progress.
