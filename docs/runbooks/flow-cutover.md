# Runbook: cutting a stage over to an engine-driven flow

Moves one pipeline stage (`<Stage>`) onto the server-side scheduler + node-job engine
(ADR 0006). Written once; W11 cut over **Spec**, W12 cut over **Plan**, W13 cut over **Code** —
substitute `<Stage>` throughout. All three stages are now cut over; the legacy `relay watch`
dispatcher and `relay_config.json` that Spec's and Plan's rituals moved a stage off of were
deleted in the Code cutover PR (RLY-139) — see "Rollback" below for what that means for a
revert.

## Why the order is not negotiable

**For Spec and Plan (RLY-136, RLY-138), while `relay watch` still ran:** two dispatchers must
never pull the same cards. The watcher loaded `relay_config.json` **once at startup**, so
removing a stage from the file without restarting the watcher left it still pulling that stage.
And the server-side flow is inert until deployed. So enabling the flow before restarting the
watcher meant both dispatchers on the same cards (double dispatch); restarting the watcher
before the deploy was live meant a stage nothing worked.

**For Code (RLY-139), with the watcher gone:** the hazard is no longer double dispatch — there
is only one dispatcher left. It is a **gap**: the flow must be enabled only once the deploy is
live *and* an executor is advertising `exclusive` capacity, or *Plan:Done* cards sit with no
dispatcher at all (the same "a stage nothing works" failure, from the opposite direction).

## The ritual (in order)

1. **Merge and deploy.** The flow definition and any engine fix must be live server-side before
   anything else changes. Confirm the deploy is healthy.
2. **Code only (RLY-139):** there is no watcher left to restart — `relay watch`,
   `relay_config.json`, `/exec-plan` and `execute-plan.js` were deleted in the cutover PR.
   Confirm on the runner machine that no old `relay watch` process is still alive
   (`pgrep -fl "relay watch"` → nothing); a stale one from before the deploy would still be
   holding the retired config in memory and would double-dispatch Code cards.
3. **Only now, enable the flow** in the board's **Settings › Flows** (RLY-142's toggle, which
   shows a runner-readiness warning before turning on: make sure a runner (`bin/relay execute`)
   is connected and advertising capacity, or cards will queue with no dispatcher to pick them
   up — RLY-139 replaced the toggle's original double-dispatch warning with this, since the
   legacy watcher it warned about is gone). No CLI or mix task — the UI toggle is the only
   enable path.
4. **Start / confirm `relay execute`** is connected and advertising `exclusive` capacity — the
   Code flow's isolation class.

   `relay execute` advertises its **configured** capacity (`.relay/executor.json`'s
   `capacity`) on its heartbeat to `POST /api/node-jobs/heartbeat`, beating once immediately at
   startup and then every `heartbeat_interval`. That beat is the only thing feeding
   `Relay.Runs.Capacity` — the store the scheduler reads to decide whether to dispatch — and
   because that store is deliberately lost on every app restart, the repeating beat is what
   makes dispatch resume by itself after a deploy. Nothing manual is required (RLY-164).

   Two things to know when diagnosing: the executor advertises its configured TOTAL, not a live
   free count (the scheduler debits in-flight `:running` runs itself), and the `name` it beats
   with is the same one it claims with, so capacity lands on the row doing the claiming.

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

**Code dogfood (RLY-139 acceptance 11, human-verify):** after the ritual, move one real
card from *Plan:Done* and watch its drawer Run tab through the run — the card should
reach *Review* with a merged PR, and the Run tab should have shown live which task each
`implement` node was working and which verdict each review returned. This cannot be
checked in-suite (it needs a real `claude`, a real executor and a real deploy);
`test/relay/runs/code_flow_e2e_test.exs` is its in-suite proxy.

## Rollback

For **Spec** and **Plan**, rollback is: disable the flow in Settings › Flows, restore the
stage's `relay_config.json` entry, restart `relay watch`.

For **Code (RLY-139) there is no legacy path left to fall back to** — the cutover PR
deleted `relay watch`, `relay_config.json`, `/exec-plan` and `execute-plan.js`. The only
lever is a revert:

1. Disable the `code` flow in **Settings › Flows** (stops new dispatch immediately).
2. `git revert <SHA>` — the pre-cutover commit is **646e7b6**
   (`rly 158 w18 create a flow from scratch (#119)`), the last commit on `main` before
   RLY-139 landed. Reverting *to* that state restores the legacy runner files.
3. Deploy the revert, then work Code cards by hand (`/write-plan` output + a human at the
   keyboard) until the engine path is fixed.

**Not rolled back:** an in-flight run's `Run` / `NodeExecution` rows persist — cancel the
run from the card's run panel if you need it gone.
