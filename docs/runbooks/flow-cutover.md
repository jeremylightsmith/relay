# Runbook: cutting a stage over to an engine-driven flow

Moves one pipeline stage (`<Stage>`) off the legacy `relay watch` dispatcher and onto the
server-side scheduler + node-job engine (ADR 0006). Written once; W11 cut over **Spec**, W12
cuts over **Plan**, W13 cuts over **Code** — substitute `<Stage>` and its `relay_config.json`
entry throughout.

## Why the order is not negotiable

Two dispatchers must never pull the same cards. The watcher loads `relay_config.json` **once at
startup** (`load_config()` at `bin/relay:514`, called from `cmd_watch`), so removing a stage from
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
5. **Watch the runners view** (`/board/:slug/runners`) for the first card through: exactly one
   dispatcher claiming, a run row appearing on the card, the executor's capacity visible.

## Verification — "it worked"

- Exactly **one** dispatcher claims each `<Stage>` card (never both watch + engine).
- A `Run` row appears on the card (its run panel / timeline shows the node starting).
- The executor and its advertised capacity are visible in the runners view.

## Rollback

1. Disable the flow in **Settings › Flows**.
2. Restore `<Stage>`'s entry in `relay_config.json`.
3. Restart `relay watch` so it reloads the restored config.

**Not rolled back:** an in-flight run's `Run` / `NodeExecution` rows persist — cancel the run from
the card's run panel if you need it gone. Rolling back the flow does not retroactively unwind a
run already in progress.
