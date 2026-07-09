# API & Setup

Relay is drivable over a small **REST API** and the zero-dependency **`bin/relay` CLI**, so a
Claude (or any) agent can pull a card, work it, and hand it back. Every write is attributed to
the board's AI agent, **"Relay AI"**.

This page gets an agent set up. For the full endpoint-by-endpoint reference — request bodies,
response shapes, and error codes — see the [REST API reference](/docs/api).

## Setup

1. **Mint a board API key.** Open your board's **Settings → API keys** (at
   `/board/:slug/settings`) and **Generate** a key. It is shown once — copy it then.
   Regenerating replaces the previous key.
2. **Point your agent's shell at the board.** Set two environment variables (for example in a
   gitignored `.envrc.local`):

   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```
3. **Confirm access.** Run `bin/relay board` — it should print your board's stages and cards.
   `bin/relay` is Python-3-stdlib only, so it runs anywhere your agent does.

## Authentication

Every `/api/*` request must carry the board key as a bearer token:

```
Authorization: Bearer <your board API key>
```

A missing or invalid key returns **`401`** with the standard error envelope that every API
error uses:

```json
{ "error": { "code": "unauthorized", "message": "..." } }
```

## Endpoints

The API is scoped to a single board and lives under `/api`: `GET /api/board`, `GET` / `POST`
on `/api/cards`, and the per-card actions under `/api/cards/:ref` (`move`, `comments`,
`needs-input`, `approve`, `reject`). The [REST API reference](/docs/api) documents each one
with request/response examples and the full status/error-code table.

## CLI quick reference

Most agents drive the API through the `bin/relay` CLI rather than raw HTTP. Common commands:

| Command | What it does |
| --- | --- |
| `bin/relay board` | Show the board: stages with their cards |
| `bin/relay card RLY-12` | One card: description, plan, branch, timeline |
| `bin/relay create "Fix login"` | Create a card (optional `--stage` / `--description` / `--tag`) |
| `bin/relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `bin/relay move RLY-12 Code` | Move the card to a stage (by name) |
| `bin/relay status RLY-12 working` | Set the card's status |
| `bin/relay describe RLY-12 @spec.md` | Set the card's description (the spec) |
| `bin/relay plan RLY-12 @plan.md` | Set the card's plan |
| `bin/relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `bin/relay approve RLY-12` / `bin/relay reject RLY-12 "note"` | Gate: advance / send back |

Text arguments accept `-` (read from stdin) or `@path` (read from a file) for long content
like specs and plans.

For the fuller agent workflow — the complete CLI table, the autonomous board runner
(`bin/relay watch`), and the operating invariants — see `docs/agent-integration.md` in the
repository.
