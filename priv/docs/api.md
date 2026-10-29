# REST API reference

Everything `./hamaca` does goes through this API, so you can do it from any language. This page
lists every endpoint, with an example request and what comes back. Each one works on a single
board: the one your key belongs to.

## Get a key

1. On your board, open **Settings → API keys** and click **+ Create new key**. Copy it now; it's
   only shown once. **Regenerate** replaces it.
2. Send it as a bearer token on every request:

   ```
   Authorization: Bearer <your board API key>
   ```
3. Check that it works. This should print your board's stages and cards:

   ```bash
   export HAMACA_API_KEY="relay_…"
   curl -H "Authorization: Bearer $HAMACA_API_KEY" https://hamaca.app/api/board
   ```

A key opens one board and nothing else. It can't sign in to the web app. Keep it out of your
repo, and regenerate it if it leaks. Whatever you change with it shows on the board as Hamaca AI.

Every endpoint needs the key except `GET /api/version` and the two scaffold endpoints, which
the install script calls before you have one.

## Conventions

- Send and receive JSON (`Content-Type: application/json`).
- A card is named by its ref, such as `RLY-12`. Wherever a path says `:ref`, use that.
- The examples use `https://hamaca.app`. If you host your own board, use its address.
- Every error has the same shape:

```json
{ "error": { "code": "not_found", "message": "Not found" } }
```

| HTTP | code | when |
| --- | --- | --- |
| 401 | `unauthorized` | the key is missing or wrong |
| 402 | `plan_paused` | the board owner's plan is unpaid; every request is refused until it's paid |
| 404 | `not_found` | no card or stage with that ref or id |
| 400 | `invalid` | the body is malformed or a field's value can't be used |
| 422 | `not_gated` | approve or reject on a card that isn't at a review stage |
| 422 | `missing_note` | reject without a note |
| 422 | `invalid_target` | reject `to` a stage the card can't go back to |
| 422 | `unknown_refs` | `depends_on` names a card this board doesn't have; nothing is written |
| 422 | `dependency_cycle` | `depends_on` would make cards wait on each other in a loop; the message names them |

## What a card looks like

Lists of cards, and every card response, use this shape:

```json
{
  "id": 42,
  "ref": "RLY-12",
  "title": "Wire up the API docs",
  "tag": "feature",
  "status": "working",
  "progress": 40,
  "branch": "rly-12-api-docs",
  "pr_url": "https://github.com/acme/app/pull/7",
  "stage_id": 5,
  "owners": [{ "type": "agent", "name": "Hamaca AI" }],
  "active_owner": "agent",
  "rejection": null
}
```

An owner is `{ "type": "agent", "name": "Hamaca AI" }` or
`{ "type": "user", "id": 3, "name": "Ada" }`. `rejection` is set after Request changes, with
the note, the stages it moved between, and who sent it back and when.

A single card (`GET /api/cards/:ref`, and every write that returns a card) adds the long fields:

```json
{
  "description": "…markdown…",
  "acceptance_criteria": "…markdown…",
  "plan": "…markdown…",
  "spec": "…markdown…",
  "depends_on": [{ "ref": "RLY-13", "title": "Ship the migration", "satisfied": false }],
  "blocks": [{ "ref": "RLY-20", "title": "Backfill the index" }],
  "timeline": [
    { "kind": "comment", "body": "on it", "author": { "type": "agent", "name": "Hamaca AI" }, "inserted_at": "…" },
    { "kind": "activity", "type": "moved", "meta": { "from_stage": "Spec", "to_stage": "Code" }, "author": { "type": "agent", "name": "Hamaca AI" }, "inserted_at": "…" }
  ]
}
```

`depends_on` lists the cards this one waits for; `satisfied` turns true when that card reaches
Done. `blocks` lists the cards waiting for this one. A flow won't pick up a card while it's
waiting, but a run that's already going carries on.

## What a stage looks like

```json
{
  "id": 9, "name": "Code:Review", "display_name": "Code · Review",
  "category": "in_progress", "type": "review", "ai_enabled": false,
  "position": 12, "wip_limit": null, "parent_id": 8,
  "description": null, "collapsed_by_default": false, "reject_to_stage_id": null
}
```

`type` is one of `queue`, `work`, `planning`, `review` or `done`, and `category` one of
`unstarted`, `planning`, `in_progress` or `complete`. [How Hamaca works](/docs/how-hamaca-works)
shows what each one looks like on the board. A substage has a `parent_id`, and its `name` is
`"<stage>:Review"` or `"<stage>:Done"`. `ai_enabled` is true when a flow works the stage; you
can't set it.

Responses from `/api/stages` also carry `problem`. It's `null` unless the stage's flow is
paused, and then it's the same explanation `GET /api/flows/:key` gives.

---

## Cards

### GET /api/board

The board's name and key, its stages, and its cards.

```
curl -H "Authorization: Bearer $HAMACA_API_KEY" https://hamaca.app/api/board
```

```json
{
  "board": { "id": 1, "name": "My board", "key": "RLY" },
  "stages": [ { "id": 1, "name": "Backlog", "…": "…" } ],
  "cards":  [ { "id": 42, "ref": "RLY-12", "…": "…" } ]
}
```

### GET /api/cards

The board's cards, leaving out the ones in Done. Add `q` to search instead.

| param | effect |
|---|---|
| `include_done=1` | Include cards in Done |
| `q=<text>` | Search by ref or title. A ref or number (`RLY-12`, `12`) comes first; otherwise every word must be in the title. Includes Done cards |
| `limit=<n>` | Return at most this many |
| `archived=1` | Include archived cards |

`./hamaca search "words"` calls this with `q`.

```
curl -H "Authorization: Bearer $HAMACA_API_KEY" "https://hamaca.app/api/cards?q=login&limit=10"
```

```json
{ "data": [ { "id": 42, "ref": "RLY-12", "…": "…" } ] }
```

### POST /api/cards

Create a card. Send a `title`, and optionally `stage` (a stage id; the first stage if you leave
it out), `description`, `acceptance_criteria`, `spec`, `tag`, `branch`, `plan`, `pr_url` and
`depends_on` (a list of refs). Returns `201` and the card. If `depends_on` names a card that
doesn't exist, nothing is created.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"title":"New card","stage":5}' https://hamaca.app/api/cards
```

### GET /api/cards/:ref

One card, with its description, spec, plan and timeline.

```
curl -H "Authorization: Bearer $HAMACA_API_KEY" https://hamaca.app/api/cards/RLY-12
```

### PATCH /api/cards/:ref

Change a card. Send any of `title`, `description`, `acceptance_criteria`, `spec`, `tag`,
`branch`, `plan`, `pr_url`, `status` (with an optional `progress`), `owners` (a list of
`"agent"` or `"user:<id>"`) and `depends_on`. `depends_on` replaces the whole list; `[]` clears
it. Returns the card.

```
curl -X PATCH -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"status":"working","progress":40}' https://hamaca.app/api/cards/RLY-12
```

Two fields have a fixed shape, and anything else in them is refused with nothing written.

`ai_result` is what the card shows when the work is done (`./hamaca result` sets it). It takes
three keys:

```json
{ "ai_result": {
    "summary": "Sign-in is one email field now.",
    "changes": ["Merges the two sign-in forms"],
    "screens": [{ "url": "/attachments/135e5539-…", "caption": "Sign in" }]
} }
```

A screen's `url` is the screenshot itself, not the page it shows. Upload it with
`POST /api/cards/:ref/attachments` (or `./hamaca attach`) and use the `/attachments/<id>` path
that returns. Any other key is refused with `422 invalid_ai_result`, naming the key.

`mockups` replaces the card's list of mockups; `[]` clears it. Each entry is a `url` and an
optional `caption`:

```json
{ "mockups": [{ "url": "/attachments/135e5539-…", "caption": "Empty state" }] }
```

The `url` must be an HTML or image file already attached to this card; anything else is
`422 invalid_mockups`. An HTML mockup runs in a sandbox. It can use inline scripts, styles and
`data:` images, and load fonts from Google Fonts (`fonts.googleapis.com` and
`fonts.gstatic.com`). Every other request is blocked. Opening a mockup that uses Google Fonts
sends a request to Google, which sees the viewer's IP address, but nothing about Hamaca.

### POST /api/cards/:ref/mockups

Add mockups to the end of a card's list without sending the whole list again. The body is the
same as PATCH's `mockups`. Returns the card.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"mockups":[{"url":"/attachments/135e5539-…","caption":"Error state"}]}' \
  https://hamaca.app/api/cards/RLY-12/mockups
```

```json
{ "data": { "ref": "RLY-12", "mockups": [
    { "url": "/attachments/8f2c1a40-…", "caption": "Empty state" },
    { "url": "/attachments/135e5539-…", "caption": "Error state" }
] } }
```

The same rules as PATCH apply to each entry. A file that's already one of the card's mockups,
the same file twice, or an empty list is `422 invalid_mockups`. A missing or non-list `mockups`
is `400`. Two agents adding mockups at once both land: neither overwrites the other.

### DELETE /api/cards/:ref/mockups/:attachment_id

Take one mockup off a card's list. `attachment_id` is the id at the end of its
`/attachments/<id>` url. The file itself stays attached to the card. Returns the card.

```
curl -X DELETE -H "Authorization: Bearer $HAMACA_API_KEY" \
  https://hamaca.app/api/cards/RLY-12/mockups/135e5539-…
```

```json
{ "data": { "ref": "RLY-12", "mockups": [
    { "url": "/attachments/8f2c1a40-…", "caption": "Empty state" }
] } }
```

An id that isn't in the list is `404 not_found`.

### POST /api/cards/:ref/move

Move a card. `stage` is a stage id or name. `position` starts at 1; leave it out to put the card
at the bottom. Returns the card.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"stage":"Plan","position":1}' https://hamaca.app/api/cards/RLY-12/move
```

A card with a run going can't leave the stage it's being worked in: `409 would_strand_run`. Cancel the run first.

### POST /api/cards/:ref/comments

Comment on a card. Send `body`. Returns `201` and the comment:

```json
{ "data": { "kind": "comment", "body": "on it", "author": { "type": "agent", "name": "Hamaca AI" }, "inserted_at": "…" } }
```

### POST /api/cards/:ref/attachments

Upload a file to a card: an image (PNG, JPEG, WebP or GIF), or an HTML mockup, up to 5 MB. Send
`filename`, `content_type` and `data_base64`. Returns `201`:

```json
{ "data": { "id": "135e5539-…", "url": "/attachments/135e5539-…", "markdown": "![shot.png](/attachments/135e5539-…)" } }
```

### GET /api/attachments/:id

Download an attachment's file. `:id` is the end of its `/attachments/<id>` path. An attachment
on another board is a `404`.

```
curl -H "Authorization: Bearer $HAMACA_API_KEY" -o mock.html https://hamaca.app/api/attachments/135e5539-…
```

### POST /api/cards/:ref/needs-input

Ask a person a question. Send `question`. The card waits until someone answers. Returns the
card.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"question":"Which auth provider?"}' https://hamaca.app/api/cards/RLY-12/needs-input
```

### POST /api/cards/:ref/approve

Approve a card at a review stage. It moves on to the next stage or substage. Returns the card,
or `422 not_gated` if the card isn't at a review stage.

### POST /api/cards/:ref/reject

Request changes. Send a `note` (required), and optionally `to`, a stage id or name to send the
card back to. Without `to`, it goes back the way the review stage is set up. Returns the card.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"note":"needs a test","to":"Plan"}' https://hamaca.app/api/cards/RLY-12/reject
```

### POST /api/cards/:ref/archive

Take a card off the board. Send `{}`. Returns the card with `"archived": true`. Any cards
waiting on it stop waiting. Archiving an archived card does nothing.

A card with a run going is refused with `409 active_run`, and nothing changes. Cancel the run
first.

### POST /api/cards/:ref/unarchive

Put an archived card back in its stage. Send `{}`. Returns the card with `"archived": false`.
Cards that stopped waiting on it when it was archived don't start waiting again.

## Tasks

A card's plan is a header (the card's `plan` field) and a list of tasks. Each task has a title
and a body, and an id that doesn't change.

### GET /api/cards/:ref/tasks

The card's tasks, without their bodies:

```json
{ "data": [ { "id": 42, "title": "Add the endpoint", "done": false, "position": 1 } ] }
```

### GET /api/cards/:ref/tasks/:id

One task, with its body.

### POST /api/cards/:ref/tasks

Add tasks after the last one, all at once. Returns `201` and the new tasks.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"tasks":[{"title":"Add the endpoint","body":"…markdown…"}]}' https://hamaca.app/api/cards/RLY-12/tasks
```

### PATCH /api/cards/:ref/tasks/:id

Change a task's `title` or `body`.

### DELETE /api/cards/:ref/tasks/:id

Remove a task. The ones after it move up; their ids stay the same.

### PATCH /api/cards/:ref/sub-tasks/:id

Tick a task off or untick it: `{"done": true}` or `{"done": false}`. Returns the card.

## Runs

A run is one trip through a flow for one card.

### GET /api/cards/:ref/diagnosis

Why isn't this card moving? One answer, with the evidence for it. It's safe to call while a run
is going. `./hamaca why` prints it.

```
curl -H "Authorization: Bearer $HAMACA_API_KEY" https://hamaca.app/api/cards/RLY-12/diagnosis
```

```json
{ "data": { "verdict": "awaiting_capacity",
  "detail": "The code flow would dispatch this card, but no runner is advertising a free shared_clean slot.",
  "evidence": { "card_ref": "RLY-12", "card_status": "ready", "flow_key": "code", "run_id": null } } }
```

| verdict | means |
| --- | --- |
| `dispatchable` | it will start shortly |
| `blocked_by_dependencies` | it's waiting for other cards to reach Done; `evidence.blocked_by` names them |
| `no_enabled_flow` | no flow works this stage |
| `flow_paused` | the flow is paused because the board around it is set up wrong; `evidence.problem` says how to fix it |
| `awaiting_capacity` | no runner has a free slot |
| `resume_refused` | a paused run can't resume; `evidence.resume_refused_reason` says why |
| `wip_full` | the stage it would move into is at its WIP limit |
| `owned_by_human` | a person has the card |
| `blocked_on_input` | it's waiting for an answer to a question |
| `run_active` | a run is going; `evidence.current_node` names the step |
| `not_eligible` | its status isn't one a flow picks up |
| `run_failed` | its last run failed; `evidence.last_execution.detail` has the error in full |
| `job_stranded` | a job has been waiting too long and no runner is answering |
| `job_awaiting_slot` | a job is waiting for a runner with a free slot; `evidence.runners` shows who has what |
| `runner_outdated` | every connected runner is too old and is being turned away; run `./hamaca update` |
| `no_runner` | no runner is connected |

### GET /api/cards/:ref/runs

The card's runs, newest first, each step with its outcome. Error details are never cut short.

```json
{ "data": [ { "id": 7, "flow_key": "code", "status": "failed", "current_node": null,
  "failure_detail": "…", "node_executions": [
    { "node_key": "final_review", "visit": 1, "attempt": 2, "outcome": "failed", "detail": "…" }
  ] } ] }
```

### POST /api/cards/:ref/retry

Rerun the card's failed run from the step that failed, or send `at` with the step to start
from. `POST /api/runs/:id/retry` does the same by run id.

### POST /api/cards/:ref/cancel

Stop the card's run. Optionally send a `reason`. The card stays where it is.
`POST /api/runs/:id/cancel` does the same by run id.

```json
{ "data": { "status": "ok", "run_id": 7, "ref": "RLY-12", "previous_status": "running", "node": "implement" } }
```

### POST /api/cards/:ref/advance

The task the run is on is already done: tick it off and go on to the next one.
`POST /api/runs/:id/advance` does the same by run id.

### POST /api/board/restart-stalled

Restart every run on the board that stopped because of something outside it, such as a network
outage. Returns how many restarted and how many were refused.

## Stages

These do what **Settings › Stages** does, and refuse the same things. A refusal can carry extra
fields in `error`:

| HTTP | code | when |
| --- | --- | --- |
| 404 | `not_found` | no such stage on this board |
| 409 | `last_stage` | deleting the board's only stage |
| 409 | `not_empty` | the stage still holds cards, archived ones included; adds `live` and `archived` counts |
| 409 | `holds_flow` | changing the type of a flow's stage to one a flow can't work; adds `flow` |
| 409 | `public_intake` | it's the stage new cards from the public form land in |
| 422 | `invalid_anchor` | `before` or `after` isn't another stage on this board |
| 422 | `not_a_main_stage` | the route needs a stage and `:id` is a substage |
| 422 | `invalid` | the stage itself is invalid, such as a blank name |
| 422 | `invalid_request` | the body is malformed; the message says how |

### GET /api/stages

Every stage in board order, each followed by its substages.

### POST /api/stages

Add a stage. Send `name`, and either `category` (to add it at the end of that category) or one
of `before` or `after` (a stage id; it goes beside that stage and takes its category).
Optionally send `type`, `description`, `wip_limit` and `collapsed_by_default`. Returns `201` and
the stage.

```
curl -X POST -H "Authorization: Bearer $HAMACA_API_KEY" -H "Content-Type: application/json" \
  -d '{"name":"Triage","after":3,"type":"queue"}' https://hamaca.app/api/stages
```

### PATCH /api/stages/:id

Change a stage: any of `name`, `description`, `type`, `wip_limit`, `collapsed_by_default` and
`reject_to_stage_id`. `null` clears `wip_limit` and `reject_to_stage_id`. Renaming a stage
renames its substages.

### POST /api/stages/:id/place

Move a stage beside another: send one of `before` or `after`. It takes that stage's category.

### PUT /api/stages/:id/substages/:lane

Turn on a stage's `review` or `done` substage.

### DELETE /api/stages/:id/substages/:lane

Turn it off. Refused while it holds cards.

### DELETE /api/stages/:id

Delete a stage, its substages, and the flow on it. Refused while it holds cards.

## Flows

### GET /api/flows

Every flow on the board. `GET /api/flows/:key` returns one. Each flow is the document you can
edit and push back, plus two fields you can't set: `derived` (the stages it takes cards from
and puts them in) and `problem`.

`problem` is `null` when the board around the flow works. When it doesn't, the flow is paused:
no new runs start until the board is fixed. `problem` explains why, in words to show as they
are:

```json
{
  "flow_key": "deploy",
  "kind": "upstream_working",
  "what": "Flow **deploy** pulls from Code, which is flow **code**'s working stage.",
  "why": "…",
  "fixes": [
    { "action": "enable_lane", "label": "Turn on Code · Done" },
    { "action": "insert_queue_stage", "label": "Insert a queue stage between Code and Deploy" }
  ],
  "columns": [ { "stage_id": 8, "name": "Code", "type": "work", "mark": "offending" } ]
}
```

### PUT /api/flows/:key

Replace a flow with an edited copy of what `GET /api/flows/:key` returned. Keep its `version`:
if someone changed the flow since you pulled it, you get a `409`, so pull again and redo your
edit. Leave `version` out to overwrite whatever is there.

### GET /api/flows/:key/metrics

How each step of the flow has done: how long it takes, what it costs, how often it retries.
`window` is `7d`, `30d` (the default) or `all`; `card=RLY-12` narrows it to one card.

### GET /api/flows/:key/audit

Warning signs in the flow's recent runs, such as a review whose verdict keeps flipping, or attempts that ended without an outcome. Takes `window` too.

## Runners

### GET /api/runners

The runners connected to this board: how many jobs each can take, when it last checked in, its
version, and what it's running.

```json
{ "data": [ { "name": "mac", "host": "mac.local", "capacity": { "shared_clean": 3, "exclusive": 1 },
  "last_heartbeat": "…", "freshness": "fresh", "stale?": false, "version": 1, "outdated": false,
  "jobs": [
    { "id": 12, "ref": "RLY-9", "node_key": "implement", "state": "running" }
  ] } ] }
```

`freshness` is `fresh`, `stale` (it missed a check-in) or `gone`. If `outdated` is true, the
runner is too old and gets no work (a `409 runner_outdated` when it asks), even though it looks
healthy. Run `./hamaca update` and restart it.

### GET /api/version

Which build of Hamaca the board is running. No key needed.

```json
{ "sha": "0123456789abcdef0123456789abcdef01234567", "built_at": "2026-07-19T10:00:00Z", "version": "0.1.0" }
```

## Used by `./hamaca` and the install script

You won't need these yourself. They're listed so you know what they are.

| Endpoint | Used for |
| --- | --- |
| `GET /api/scaffold` | The list of files `./hamaca update` keeps current. No key needed. `503 scaffold_unavailable` on a board that hasn't built them |
| `GET /api/scaffold/*path` | One of those files. No key needed |
| `POST /api/setup/preflight` | The install script's checks of your repo, before it writes anything |
| `POST /api/setup/installed` | The install script reporting that it finished |
| `GET /api/setup` | The setup checklist (`./hamaca setup status`) |
| `POST /api/setup/steps/:step` | Reporting one setup step (`./hamaca setup report`) |
| `GET /api/board/version` | A number that goes up whenever the board changes, so a client knows when to reload |
| `POST /api/board/heartbeat` | The runner checking in |
| `POST /api/board/logs` | The runner sending its log to the board |
| `GET /api/harnesses` | The runner reading which agent tools the board's flows use |
| `POST /api/node-jobs/claim` | The runner taking a job |
| `POST /api/node-jobs/heartbeat` | The runner saying a job is still going |
| `POST /api/node-jobs/:id/outcome` | The runner reporting how a job went |
| `POST /api/talk/turns/:id/events` | The runner sending an agent conversation to the board as it happens |
| `POST /api/talk/turns/:id/outcome` | The runner reporting how that conversation turn ended |

How the runner uses these is on the [Runner](/docs/architecture-runner) page.
