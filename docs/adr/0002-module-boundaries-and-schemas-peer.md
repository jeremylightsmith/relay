# ADR 0002 — Module boundaries (`boundary`) + a `Schemas` peer

## Status

Accepted

## Context

Hamaca has two layers that must not tangle: the domain (`Hamaca.*` contexts) and the web layer
(`HamacaWeb.*`). Both need the same structs — a LiveView renders a `Card`, a context writes one
— and most contexts need structs owned by another concept (`Cards` reads `Stage` and `Board`,
`Runs` reads `Card`). If each schema lived inside the context that "owns" it, every struct
reference would become a context-to-context dependency, and those artificial edges breed cycles
(`Boards → Cards → Boards`) as cross-cutting schemas multiply.

## Decision

- **Boundaries are compiler-enforced** with [`boundary`](https://hexdocs.pm/boundary)
  (`compilers: [:boundary, ...]` in `mix.exs`). A violation fails `mix compile`, and so
  `mix precommit`.
- **`Schemas` is a top-level peer boundary** (`lib/schemas.ex`, modules under `lib/schemas/`)
  with `deps: []`. It holds the Ecto schemas, their changesets, the closed vocabularies each
  schema owns (`Schemas.Card.statuses/0`, `Schemas.Stage.types/0`, …), and pure functions over
  that data (`Schemas.Stage.valid_status?/2`). It never touches the Repo or calls a context;
  anything with side effects lives in a context. Schemas may reference each other freely.
  `Schemas.Scope` (the `current_scope` struct) lives here too.
- **`Hamaca` is the domain boundary** (`lib/hamaca.ex`, `deps: [Schemas]`). Each context is its
  own sub-boundary with `use Boundary` and is listed in `Hamaca`'s `exports`. A context declares a
  dep on another context only when it calls that context's behaviour, never just to name a struct.
- **`HamacaWeb`** depends on `[Hamaca, Schemas]`: it reads schema structs and calls exported
  context functions. Contexts never depend on the web layer.
- **`Hamaca.Application`** is the one `top_level?` boundary that depends on both.
- Every new schema is born in `Schemas.*`.

The current graph is generated into [`../architecture/deps.md`](../architecture/deps.md) by
`mix hamaca.deps_graph`.

## Consequences

- Cross-layer coupling is explicit and checked at compile time.
- Context-to-context edges in the graph are real behavioural dependencies, so a cycle is a design
  problem to solve, not a struct to move. When one appears, the function moves to the side that
  may depend on the other (for example `Hamaca.Cards.update_stage/2` lives in `Cards` because
  `Boards → Cards` would be a cycle), or the other side observes events instead of calling
  (`Hamaca.Runs.Listener`).
- Adding a context means `use Boundary`, an entry in `Hamaca`'s `exports`, and a
  `docs/architecture/domain.md` update.
- Because a schema owns its closed sets, the web layer and every context can call the same
  definition, which is what the "a magic value is defined exactly once" rule in `AGENTS.md` relies
  on.
