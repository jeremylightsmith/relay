# API Reference

Relay exposes a small JSON REST API scoped to a single **board**. It is the same
entry point the `bin/relay` CLI uses, so anything the CLI does you can do directly.

## Base URL & authentication

All endpoints live under `/api` and require a **board API key**:

```
Authorization: Bearer <board API key>
```

Mint a key at **`/board/:slug/settings` → API keys** (each board has a single key;
regenerating replaces it). Every write is attributed to **"Relay AI"** (the agent
actor). Requests without a valid key get `401 unauthorized`.

## Conventions

- **JSON in, JSON out.** Send `Content-Type: application/json`; responses are JSON.
- **Card refs.** Cards are addressed by their human ref, e.g. `RLY-12` (the board key
  plus the card number). Wherever a path says `:ref`, use that.
- **Errors** use a consistent envelope:

```json
{ "error": { "code": "not_found", "message": "Not found" } }
```

| HTTP | code | when |
| --- | --- | --- |
| 401 | `unauthorized` | missing/invalid `Authorization` bearer key |
| 404 | `not_found` | no card/stage matches the ref/id |
| 400 | `invalid` | malformed body or unusable field values |
| 422 | `not_gated` | approve/reject on a card whose stage is not an approval gate |
| 422 | `missing_note` | reject without a non-empty `note` |
| 422 | `invalid_target` | reject `to` a stage that isn't a valid main-lane target |

## Card & stage shape

Cards are serialized by `CardJSON`. The **base shape** (returned in lists and as the
`data` of every card response):

```json
{
  "id": 42,
  "ref": "RLY-12",
  "title": "Wire up the API docs",
  "tag": "feature",
  "status": "working",
  "progress": 40,
  "branch": "rly-12-api-docs",
  "pr_url": "https://github.com/acme/relay/pull/7",
  "stage_id": 5,
  "owners": [{ "type": "agent", "name": "Relay AI" }],
  "active_owner": "agent",
  "rejection": null
}
```

`owners` entries are either `{ "type": "agent", "name": "Relay AI" }` or
`{ "type": "user", "id": 3, "name": "Ada" }`. `rejection`, when present, is
`{ "note", "from_stage", "to_stage", "rejected_by", "rejected_at" }`.

The **single-card** responses (`show`, and every write that returns a card) add the
heavy fields:

```json
{
  "description": "…markdown…",
  "plan": "…markdown…",
  "spec": "…markdown…",
  "timeline": [
    { "kind": "comment", "body": "on it", "author": { "type": "agent", "name": "Relay AI" }, "inserted_at": "…" },
    { "kind": "activity", "type": "moved", "meta": { "from_stage": "Spec", "to_stage": "Code" }, "author": { "type": "agent", "name": "Relay AI" }, "inserted_at": "…" }
  ]
}
```

A **stage** (returned inside `GET /api/board`):

```json
{
  "id": 5, "name": "Plan", "category": "started", "owner": "ai",
  "position": 3, "approval_gate": false, "reject_to_stage_id": null,
  "wip_limit": null, "lane": "main", "parent_id": null
}
```

---

## Endpoints

### GET /api/board

The whole board: its identity, stages, and cards (base shape).

```
curl -H "Authorization: Bearer $RELAY_KEY" https://relay.example/api/board
```

```json
{
  "board": { "id": 1, "name": "My board", "key": "RLY" },
  "stages": [ { "id": 1, "name": "Backlog", "…": "…" } ],
  "cards":  [ { "id": 42, "ref": "RLY-12", "…": "…" } ]
}
```

### GET /api/cards

All cards on the board (base shape).

```json
{ "data": [ { "id": 42, "ref": "RLY-12", "…": "…" } ] }
```

### POST /api/cards

Create a card. Optional `stage` (a stage **id**; defaults to the board's first stage).
Accepts `title`, `description`, `spec`, `tag`, `branch`, `plan`, `pr_url`. Returns
`201` with the single-card shape.

```
curl -X POST -H "Authorization: Bearer $RELAY_KEY" -H "Content-Type: application/json" \
  -d '{"title":"New card","stage":5}' https://relay.example/api/cards
```

```json
{ "data": { "id": 43, "ref": "RLY-13", "title": "New card", "…": "…" } }
```

### GET /api/cards/:ref

One card, single-card shape (with `description`, `plan`, `spec`, `timeline`).

```
curl -H "Authorization: Bearer $RELAY_KEY" https://relay.example/api/cards/RLY-12
```

### PATCH /api/cards/:ref

Update a card. Any of `title`, `description`, `spec`, `tag`, `branch`, `plan`,
`pr_url`; plus `status` (with optional `progress`); plus `owners` (a list of
`"agent"` or `"user:<id>"`). Returns the single-card shape.

```
curl -X PATCH -H "Authorization: Bearer $RELAY_KEY" -H "Content-Type: application/json" \
  -d '{"status":"working","progress":40}' https://relay.example/api/cards/RLY-12
```

### POST /api/cards/:ref/move

Move a card. `stage` is a stage **id or name**; `position` is **1-based** (omit to
append). Returns the single-card shape.

```
curl -X POST -H "Authorization: Bearer $RELAY_KEY" -H "Content-Type: application/json" \
  -d '{"stage":"Plan","position":1}' https://relay.example/api/cards/RLY-12/move
```

### POST /api/cards/:ref/comments

Add an agent comment. Requires `body`. Returns `201` with the new timeline entry:

```json
{ "data": { "kind": "comment", "body": "on it", "author": { "type": "agent", "name": "Relay AI" }, "inserted_at": "…" } }
```

### POST /api/cards/:ref/needs-input

Flag the card as needing human input. Requires `question`. Returns the single-card
shape.

```
curl -X POST -H "Authorization: Bearer $RELAY_KEY" -H "Content-Type: application/json" \
  -d '{"question":"Which auth provider?"}' https://relay.example/api/cards/RLY-12/needs-input
```

### POST /api/cards/:ref/approve

Approve a card sitting on an approval-gate stage (advances it). `422 not_gated` if the
card's stage is not a gate. Returns the single-card shape.

### POST /api/cards/:ref/reject

Send a card back. Requires a non-empty `note` (else `422 missing_note`). Optional `to`
(a stage id or name) routes to a specific earlier main-lane stage; an unresolvable
target is `422 invalid_target`. Without `to`, uses the gate's reject flow. Returns the
single-card shape.

```
curl -X POST -H "Authorization: Bearer $RELAY_KEY" -H "Content-Type: application/json" \
  -d '{"note":"needs a test","to":"Plan"}' https://relay.example/api/cards/RLY-12/reject
```

---

## CLI

Most of the time you'll drive this API through the `bin/relay` CLI rather than raw
HTTP — it wraps pull/work/hand-back into a few commands. See `docs/agent-integration.md`
in the repository for the full agent workflow.
