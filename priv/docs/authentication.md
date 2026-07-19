# Authentication & API access

Relay is drivable over a small **REST API** and the zero-dependency **`relay` CLI**, so a
Claude (or any) agent can pull a card, work it, and hand it back. Every write is attributed
to the board's AI agent, **"Relay AI"**.

This page covers how a request proves who it is. If you are setting up for the first time,
start at [Getting started](/docs/getting-started). For the full endpoint-by-endpoint
reference — request bodies, response shapes, and error codes — see the
[REST API reference](/docs/api).

## Get a board API key

1. **Mint the key.** Open your board's **Settings → API keys** (at
   `/board/:slug/settings`) and click **+ Create new key**. It is shown once — copy it
   then. If a key already exists, **Regenerate** replaces it.
2. **Point your agent's shell at the board.** Set two environment variables (for example in
   a gitignored `.envrc.local`):

   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```
3. **Confirm access.** Run `relay board` — it should print your board's stages and cards.
   The CLI is Python-3-stdlib only, so it runs anywhere your agent does.

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

## Scope

A board API key authorises exactly one board. It is not a user credential: it cannot sign
in to the web UI, and it carries no access to any other board. Treat it like a deploy key —
keep it out of the repository, and regenerate it if it leaks.

## Endpoints

The API is scoped to a single board and lives under `/api`: `GET /api/board`, `GET` /
`POST` on `/api/cards`, and the per-card actions under `/api/cards/:ref` (`move`,
`comments`, `needs-input`, `approve`, `reject`). The [REST API reference](/docs/api)
documents each one with request/response examples and the full status/error-code table.

For the commands most agents actually use, see the [CLI](/docs/cli); for the runner and its
operating rules, see [Agent integration](/docs/agent-integration).
