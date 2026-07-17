# 17 — Card activity: entry model, health strip, flat timeline

**Why.** `docs/designs/Relay Card Activity.dc.html` is a **committed spec** ("this is
the committed design"): today an agent's work on a card is invisible until you open it
and squint, and a dead agent surfaces nothing. This card is buildable *now* (it evolves
RLY-112's logging, independent of the flow engine) and is groundwork W1/W8 render on.

**Scope — the artboard's own build order.**

1. **Entry model + append API**: one flat, append-only list per card;
   `{id, card_id, kind: action|move|decision|failure|heartbeat, actor, text, run_id,
   from/to stage ids, inserted_at}`. `run_id` captured from day one so grouping by run
   later needs no backfill; `heartbeat` stored but never rendered.
2. **Health, derived — never stored**: pure function of the newest entry
   (failure → *stopped*; no active agent → none; age > `STALE_AFTER` (~3× heartbeat,
   one global timeout to start) → *stale*; else *live*).
3. **Collapsed-card strip**: one health-coloured line — dot · newest entry · relative
   time (replaces the old `working · %` label); stale/stopped fires the existing
   needs-you pulse; *stopped* shows **Retry** (re-dispatches on the same card,
   appending an `action` entry — history never cleared).
4. **Timeline section** in the card detail, after Comments — flat, newest-first, never
   grouped; moves render as full-width divider chips; header carries the health chip.
5. Explicitly **not v1** (per the artboard): filters, verbose toggle, run grouping.

**Acceptance criteria.**

1. With an agent working a card, the collapsed card shows the live strip updating over
   the socket; killing the runner flips it to stale within `STALE_AFTER`, and a failure
   entry flips it to stopped with Retry.
2. The detail timeline shows entries + move dividers newest-first, matching the
   artboard; heartbeats never render.
3. Every runner feed line lands as exactly one entry with `run_id` populated.
4. Storybook stories for strip + timeline states. `mix precommit` passes.
