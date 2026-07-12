# Relay glossary

The canonical vocabulary for Relay's board model. When code, docs, or UI copy disagree, this
file wins. RLY-76 standardized the **stage / substage** terminology and the Approve advance rule
below; this glossary is the routing authority (superseding earlier "next main stage" phrasing in
the MMF design specs).

- **Board** — a single kanban board (`Schemas.Board`). Owns an ordered set of stages and its cards.
- **Stage (main stage)** — a top-level column on the board: `Schemas.Stage` with
  `parent_id == nil`, ordered by `position`.
- **Substage** — a child stage of a main stage (`parent_id` set), always `type in [:review, :done]`.
  Displayed as `"<Parent> · Review"` / `"<Parent> · Done"` (see `Boards.stage_display_name/1`).
  **This is the canonical name for what the code currently calls a "sub-lane" / "lane"** — those
  identifiers (`Boards.sublanes/1`, `enable_lane/2`, `has_many :sublanes`) are legacy names for
  *substage* and have not yet been renamed.
- **Category** — the coarse board grouping a main stage belongs to (`:unstarted | :planning |
  :in_progress | :complete`), used for ordering and the Done derivation.
- **Stage type** — a stage's behavior type: `queue | work | planning | review | done`. Types drive
  the claim rule and the arrival status (`Schemas.Stage.default_status/1`).
- **Card** — a unit of work (`Schemas.Card`) that lives in exactly one stage/substage at a time.
- **Status** — a card's lifecycle state: `ready | working | needs_input | in_review`. A stage
  type's default status is applied on arrival when the current status isn't valid there (ADR 0003).
- **Baton / ownership** — who holds the card: **Human = blue** (`--color-primary`), **AI = violet**
  (`--color-secondary`). An **unowned** card claims an owner when it *enters* a work/planning
  stage (the mover decides); an already-owned card keeps its owners through every move.
- **Review gate** — the Approve / Request-changes decision shown for a card whose stage is
  `:review`-type (main or substage). **Approve advances the card to the next stage or substage;**
  **Request changes** sends it back to a derived destination.
- **The "next stage or substage" advance rule (Approve)** — the single governing rule:
  - Card in a **review substage** → the parent's **Done substage** if it exists, else the next
    main stage after the parent.
  - Card in a **top-level review stage** → the next main stage.
  - No next stage/substage (terminal) → complete **in place** (`:ready`, which derives Done).

  Implemented by `Cards.approve_target/1` + `Cards.approve/2` (RLY-76 is the routing authority).
- **Done (derived)** — a card is *Done* only when it is `:ready` at the board's **terminal** stage.
  A `:ready` card in a **mid-board Done substage** is **parked**, not done (`Cards.done?/2` is
  false there). Done is derived, never a stored flag.

See also: `Schemas.Stage`, [ADR 0003](adr/0003-card-state-stage-type-validity.md), and card
**RLY-76** (the Approve routing authority).
