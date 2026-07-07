# ADR 0002 — Module boundaries (`boundary`) + a `Schemas` peer

## Status
Accepted (2026-07-07)

## Context

The domain (`Relay.*` contexts) and web (`RelayWeb.*`) layers already use
[`boundary`](https://hexdocs.pm/boundary) as a compiler (wired in `mix.exs` via
`compilers: [:boundary, ...]`), with each context a sub-boundary of `Relay`. But the Ecto
schemas lived *inside* the contexts (`Relay.Cards.Card`, `Relay.Boards.Stage`, …), which
forces schema-only coupling to masquerade as context coupling: `Relay.Cards` depended on
`Relay.Boards` solely to reference the `Board`/`Stage` structs, and `Relay.Boards` depended
on `Relay.Accounts` solely for the `User` struct. As MMF 06+ add cross-cutting schemas
(`CardOwner`, later `Comment`, `Activity`, `ApiKey`), that pattern breeds artificial
dependencies and, eventually, cycles. The reference is the sibling project `throughway`
(its ADR 0004), where a peer `Schemas` namespace dissolved the same problem.

## Decision

- **`Schemas` is a top-level peer boundary** at `lib/schemas/` (modules `Schemas.*`),
  holding plain `use Ecto.Schema` modules + their changesets, with
  `use Boundary, deps: [], exports: [Board, Card, CardOwner, Scope, Stage, User]`.
  Schemas may reference each other freely inside the boundary. Schemas hold data, not
  business logic — logic stays in the contexts.
- `Schemas.Scope` (the `current_scope` struct) lives here too: it is a plain struct shared
  by web and domain, exactly the kind of type the peer exists for.
- **Boundary shape** (deps are minimal and compiler-enforced). Because `boundary` requires a
  nested boundary's cross-top-level dependencies to also be declared on its top-level
  ancestor (a sub-boundary may only depend on its parent, a sibling, or a dep of its
  parent), `Relay` itself lists `Schemas` as a dep so its child contexts can reach it:

  | Boundary | `deps:` |
  | --- | --- |
  | `Relay.Repo`, `Relay.Mailer` | `[]` (leaves) |
  | `Relay.Accounts` | `[Relay.Repo, Schemas]` |
  | `Relay.Boards` | `[Relay.Repo, Schemas]` |
  | `Relay.Cards` | `[Relay.Repo, Schemas]` |
  | `Relay` (root) | `[Schemas]`, exports `[Repo, Mailer, Accounts, Boards, Cards]` |
  | `RelayWeb` | `[Relay, Schemas]`, exports `[Endpoint, Telemetry]` |
  | `Relay.Application` | `top_level?: true, deps: [Relay, RelayWeb]` |

  Note the context-to-context deps disappeared: they were schema references all along.
- **All new schemas** (MMF 06's `CardOwner`; later `Comment`, `Activity`, `ApiKey`) are
  born in `Schemas.*`.

## Consequences

- Cross-layer coupling is explicit and compiler-checked; a boundary violation fails
  `mix compile` (and therefore `mix precommit`).
- The one-time mechanical cost: 5 schema modules moved/renamed and every alias updated
  (done in MMF 06, no behaviour change).
- Contexts stay the only place with business logic; the web layer reads schema structs and
  calls exported context functions — same rule as before, now with the struct types in a
  shared, dependency-free home.
