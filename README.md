# Relay

**Relay is an AI-first kanban board.** Its organizing idea is *passing the baton*: work
moves back and forth between humans and AI agents, and the board makes each hand-off
explicit — whose turn it is, what's waiting on a person, and what an agent is actively
working. "Who holds the baton" is a first-class property of every card.

- **Product north star:** [`docs/vision.md`](docs/vision.md)
- **Architecture decisions:** [`docs/adr/`](docs/adr/README.md)
- **How AI agents should work in this repo:** [`AGENTS.md`](AGENTS.md)

## Stack

- **Elixir + Phoenix LiveView** — the single source of truth for UI and real-time logic.
- **PostgreSQL** via Ecto.
- **Tailwind v4 + daisyUI** for styling; **phoenix_storybook** as the home for reusable components.
- **[`boundary`](https://hexdocs.pm/boundary)** enforces context/web boundaries at compile time.
- **Mobile** ships as a thin native wrapper around the LiveView UI — no separate client or API.
  See [ADR 0001](docs/adr/0001-client-architecture.md).

## Getting started

Toolchain versions are pinned in [`mise.toml`](mise.toml) (Elixir/Erlang/Node). With
[`mise`](https://mise.jdx.dev) installed:

```sh
mise install                 # install pinned Elixir/Erlang/Node (one-time)
mix setup                    # deps, create+migrate db, install+build assets
mix phx.server               # or: iex -S mix phx.server  (also: make serve)
```

Then visit:

- <http://localhost:4003> — the app
- <http://localhost:4003/storybook> — component storybook (dev only)
- <http://localhost:4003/dev/dashboard> — LiveDashboard (dev only)

Postgres must be running locally with a `postgres` / `postgres` role (see
`config/dev.exs`), or adjust that config to your local setup.

## Everyday commands

| Command | What it does |
| --- | --- |
| `mix precommit` (`make precommit`) | Full gate: compile (warnings-as-errors), format (Styler), `credo --strict`, `sobelow`, `deps.audit`, tests. **Must pass before work is done.** |
| `mix test` (`make test`) | Fast, browser-free test suite. |
| `mix test.browser` | Playwright browser journeys (builds assets first). |
| `iex -S mix phx.server` (`make serve`) | Run the app with an IEx shell. |

## AI-assisted workflow

This repo ships a Claude Code toolkit under `.claude/`: skills (TDD, systematic debugging,
verification, brainstorming, …) and a command pipeline — `/brainstorm` → `/write-plan` →
the Code flow → `/finish`. `AGENTS.md` documents how these are expected to be used.

## Repository layout

```
lib/relay/          Domain contexts (each a boundary sub-module; add to Relay's exports)
lib/relay_web/      LiveViews, components, router, endpoint (the RelayWeb boundary)
storybook/          Component stories (surfaced at /storybook)
docs/adr/           Architecture Decision Records
docs/vision.md      Product vision
.claude/            Skills, agents, commands, and workflows for AI-assisted development
.github/workflows/  CI (fast suite + browser journeys; Fly deploy is stubbed until launch)
```
