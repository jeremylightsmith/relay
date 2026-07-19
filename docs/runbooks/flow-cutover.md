# Enabling a flow safely

How to turn a board stage over to an engine-driven flow (ADR 0006) without either
double-dispatching cards or stranding them with no dispatcher at all. Written for **any**
stage on **any** board — substitute your stage for `<Stage>` throughout. Relay's own
three-stage cutover is a historical note at the end.

## Why the order matters

Every failure mode here is a *dispatcher count* problem, and there are only two of them:

- **Two dispatchers on the same cards.** If anything else is already pulling `<Stage>` —
  another board's flow, a hand-run agent loop, a legacy watcher — enabling a flow on that
  stage means both claim the same cards and stomp each other's branches.
- **Zero dispatchers.** A flow definition is inert until it is deployed, and a deployed
  flow still dispatches nothing unless an executor is advertising the isolation class the
  flow's nodes ask for. Enable the flow before either is true and `<Stage>` cards simply
  sit in *Next up* looking broken.

The ritual below is ordered so neither window is ever open.

## The ritual (in order)

1. **Deploy first.** The flow definition and any engine fix must be live server-side
   before anything else changes. Confirm the deploy is healthy.

2. **Confirm nothing else dispatches `<Stage>`.** No second flow enabled on the same
   stage, and no hand-run agent loop or external process claiming its cards. A dispatcher
   that loaded its configuration at startup will still be pulling the stage until it is
   actually stopped — check the process, not the config file.

3. **Turn the flow on** in the board's **Settings › Flows**. The toggle is the only enable
   path — there is no CLI or mix task. It shows a runner-readiness warning before turning
   on: if no executor is connected and advertising capacity, cards will queue with no
   dispatcher to pick them up.

4. **Confirm an executor is advertising the right capacity class.** Start (or check)
   `relay execute` and open the board's **Runners** view at `/board/:slug/runners`. The
   executor should show a **FRESH** pill and capacity chips for the class the flow's nodes
   need — `exclusive` for a flow whose nodes take a dedicated worktree, `shared_clean` for
   one that does not.

   `relay execute` advertises its **configured** capacity (`.relay/executor.json`'s
   `capacity`) on its heartbeat, beating once immediately at startup and then every
   `heartbeat_interval` seconds. That beat is the only thing feeding the capacity store the
   scheduler reads, and because that store is deliberately lost on every app restart, the
   repeating beat is what makes dispatch resume by itself after a deploy. Nothing manual is
   required.

   Two things to know when diagnosing: the executor advertises its configured **total**,
   not a live free count (the scheduler debits in-flight runs itself), and the `name` it
   beats with is the same one it claims with, so capacity lands on the row doing the
   claiming.

5. **Confirm a card actually dispatches.** Watch the first `<Stage>` card in *Next up*
   pick up a `Run` row rather than sitting idle.

## Verification — "it worked"

- Exactly **one** dispatcher claims each `<Stage>` card.
- The executor shows **FRESH** with the expected capacity chips on `/board/:slug/runners`.
- A `Run` row appears on the card — its run panel / timeline shows the node starting —
  within one scheduler tick of the capacity beat landing.
- Open the card's drawer **Run** tab and watch one real card through the flow end to end.
  That is the only check that proves the agent nodes themselves work; it needs a real
  executor and a real deploy, so it cannot be done in a test suite.

## Rollback

1. **Disable the flow** in **Settings › Flows**. This stops new dispatch immediately and is
   always the first move.
2. Work `<Stage>` cards by hand until the flow is fixed.
3. If the flow definition itself is at fault, revert the deploy that introduced it.

**Not rolled back:** an in-flight run's `Run` / `NodeExecution` rows persist — cancel the
run from the card's run panel if you need it gone.

## How Relay itself cut over

Historical, and kept only because the hazards it names are the ones the ritual above is
shaped around. Relay moved three stages onto the engine in sequence: **Spec** (RLY-136),
**Plan** (RLY-138), then **Code** (RLY-139).

For Spec and Plan, a legacy `relay watch` dispatcher was still running, so the hazard was
**double dispatch**: the watcher loaded `relay_config.json` once at startup, so removing a
stage from that file without restarting the watcher left it still pulling the stage.

For Code the watcher was gone, so the hazard inverted to a **gap**: with only one
dispatcher left, enabling the flow before an executor advertised `exclusive` capacity meant
*Plan:Done* cards sat with nothing to work them. The Code cutover PR deleted `relay watch`,
`relay_config.json`, `/exec-plan` and `execute-plan.js`, so there is no legacy path left to
fall back to — the only lever is the revert described under Rollback.
