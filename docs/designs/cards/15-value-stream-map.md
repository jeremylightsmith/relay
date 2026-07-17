# 15 — Value stream map

**Why.** The one thing the "every node a column" thought experiment got right —
cross-card bottleneck visibility — as an analytics view instead of board columns.
Designed in `docs/designs/Relay Value Stream Map.dc.html`: derive per-stage
**working vs waiting** spans from the event stream Relay already keeps, draw the
sawtooth, name the waste.

**Scope (per the artboard).**

- Derivation, nothing new tracked: fold each card's events into per-stage spans —
  *working* (an owner actively on it) vs *waiting* (parked, queued, or blocked on a
  human) — plus agent spend per stage (run costs land on events per the Card Activity
  spec's `run_id`).
- Two scopes: **one card** (process boxes + sawtooth timeline + lead time / working
  time / flow efficiency / agent $) and **last-20-averaged** (the system diagnosis:
  longest rise = biggest wait; fattest $ box = money sink; flow efficiency as the one
  trended number).
- Plain-English glosses on every Lean term, per the artboard.
- **Explicitly parked** (artboard §05, undecided): the needed-vs-over-work valley
  split — requires a per-task cost baseline that doesn't exist; prototype the baseline
  before committing to that lens.

**Acceptance criteria.**

1. For a real shipped card, the one-card map's spans reconcile with its timeline
   events, and lead/working/efficiency numbers are arithmetically consistent.
2. The averaged view over the last 20 done cards renders and updates as cards ship.
3. Matches the artboard's elements (inventory triangles, sawtooth, stat tiles, kaizen
   flag on the longest wait). `mix precommit` passes.
