# Plan: RLY-14 — Create cards with the REST API

## Goal
Add the HTTP + CLI surface for creating a card on the authenticated board. The domain
work already exists in `Relay.Cards.create_card/3` (ref allocation, append-to-stage,
`:created` activity log, live broadcast). This plan adds:

1. `POST /api/cards` — a new action on the existing `RelayWeb.Api.CardController`.
2. `relay create` — a new command on the live Python CLI (`bin/relay`), plus a docs table row.

## Architecture
- **Web layer only + one CLI file.** No context/schema/migration changes — `create_card/3`,
  `Boards.list_stages/1`, and the shared `CardJSON.show` shape are all reused as-is.
- The controller `create/2` mirrors the existing `move/2`: board + `:agent` actor come from
  `conn.assigns.current_board` (set by `RelayWeb.ApiAuth`), a stage is resolved from
  `params["stage"]` (reusing `move/2`'s private `get_stage/2`), and success renders the
  standard `:show` view with `put_status(:created)` (mirroring the `comments/2` action).
- Stage resolution rule: **no `stage` → board's first stage in position order**
  (`Boards.list_stages/1` |> hd); **explicit `stage` that doesn't resolve → 404**;
  **missing/blank `title` → 400** (via `Card.changeset`'s `validate_required([:title])` →
  `FallbackController`'s changeset path).

## Tech
Elixir / Phoenix 1.8, Ecto, `Phoenix.ConnTest` for controller tests. Python 3 stdlib for the
CLI (`bin/relay` is a self-contained `argparse` script, no test framework — verified by
running the parser).

## Global Constraints (from the spec)
- Owners, status, and position are **not** settable at create time: a new card is `:queued`,
  unowned, appended to the bottom of its stage (whatever `create_card/3` does). Clients set
  owners/status with a follow-up `PATCH /api/cards/:ref`.
- `POST /api/cards` goes in the **existing** authenticated `scope "/api", RelayWeb.Api` block
  (`pipe_through [:api, :api_auth]`), routed to `CardController.create`.
- **201 Created** body is the standard `CardJSON.show` shape (card fields + `description` +
  `timeline`), identical to `GET`/`PATCH`.
- **400 `invalid`** on missing/blank `title`; **404 `not_found`** on an explicit `stage` id
  that doesn't resolve to a stage on this board (uncastable *or* unknown id).
- Passing the raw `params` map through to `create_card/3` is safe — `Card.changeset/2` only
  casts editable fields; `ref`, `stage`, etc. are ignored.
- CLI: add to `bin/relay` only. The Elixir `mix relay` CLI (`lib/relay/cli.ex`) is **not**
  kept in sync with the newer per-card commands (it has no `describe`/`plan`/`branch`/`pr`),
  so `create` follows the same pattern and is **not** added there.
- Update the CLI reference table in `docs/agent-integration.md` with the new command.

### Non-goals
- Bulk/batch create, MMF dedup/import (the follow-up work this card enables).
- Setting owners/status/position at create time (use existing `PATCH`).
- Any new UI — creation from the board UI is out of scope.

---

## Task 1: `POST /api/cards` endpoint

Add the route and the `create/2` controller action (with its two stage-resolution helper
clauses), driven by controller tests covering every response branch.

**Files**
- Modify: `lib/relay_web/router.ex` (add the `post "/cards"` route)
- Modify: `lib/relay_web/controllers/api/card_controller.ex` (add `create/2` + `resolve_create_stage/2`)
- Test: `test/relay_web/api/card_controller_test.exs` (new `describe "POST /api/cards"` block)

**Interfaces**

*Consumes* (all already exist — exact signatures this task calls):
- `Relay.Cards.create_card(%Schemas.Stage{} = stage, attrs :: map, actor :: :agent | {:user, integer})` → `{:ok, %Schemas.Card{}} | {:error, %Ecto.Changeset{}}`. `attrs` may be the raw string-keyed params map.
- `Relay.Boards.list_stages(%Schemas.Board{})` → `[%Schemas.Stage{}]` in position order.
- `RelayWeb.Api.CardController.get_stage(board, stage_id)` (existing private helper on this module): integer/integer-string id → `%Schemas.Stage{}`; uncastable/unknown → `nil`.
- `Relay.Activity.list_timeline(%Schemas.Card{})` → list of activity/comment structs.
- `CardController` already has `action_fallback RelayWeb.Api.FallbackController`, which maps `{:error, %Ecto.Changeset{}}` → 400 `invalid` and `{:error, :not_found}` → 404, and `{:error, :invalid_request}` → 400 `invalid`.

*Produces*:
- Route `POST /api/cards` → `RelayWeb.Api.CardController.create/2`.
- `RelayWeb.Api.CardController.create(conn, params)` — renders `:show` with `put_status(:created)` on success; returns `{:error, ...}` tuples otherwise (handled by the fallback controller).

**Steps**

- [x] Write the failing controller tests. Append this `describe` block to
  `test/relay_web/api/card_controller_test.exs` (the file's `setup` already provides
  `conn` with a valid `Bearer` token, `board`, and a persisted `stage` named `"Spec"` at
  `position: 1` — the board's only/first stage):

  ```elixir
  describe "POST /api/cards" do
    test "creates a queued, unowned card in the board's first stage with title only",
         %{conn: conn, stage: stage} do
      body =
        conn
        |> post(~p"/api/cards", %{title: "New card"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["title"] == "New card"
      assert body["status"] == "queued"
      assert body["stage_id"] == stage.id
      assert body["owners"] == []
      assert body["active_owner"] == nil
      assert is_binary(body["ref"])
      # standard show shape includes description + timeline
      assert Map.has_key?(body, "description")
      assert is_list(body["timeline"])
    end

    test "creates a card into an explicit stage id", %{conn: conn, board: board} do
      other = insert(:stage, board: board, name: "Code", owner: :ai, position: 2)

      body =
        conn
        |> post(~p"/api/cards", %{title: "Into code", stage: other.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == other.id
    end

    test "accepts an integer-string stage id", %{conn: conn, board: board} do
      other = insert(:stage, board: board, name: "Code", owner: :ai, position: 2)

      body =
        conn
        |> post(~p"/api/cards", %{title: "Into code", stage: to_string(other.id)})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == other.id
    end

    test "created card appears in GET /api/cards", %{conn: conn} do
      conn |> post(~p"/api/cards", %{title: "Findable"}) |> json_response(201)

      titles =
        conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])

      assert "Findable" in titles
    end

    test "records a :created timeline entry attributed to the agent", %{conn: conn} do
      body = conn |> post(~p"/api/cards", %{title: "Logged"}) |> json_response(201) |> Map.fetch!("data")

      assert Enum.any?(body["timeline"], fn e ->
               e["kind"] == "activity" and e["type"] == "created" and e["author"]["name"] == "Relay AI"
             end)
    end

    test "missing title returns 400", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{}) |> json_response(400)
    end

    test "blank title returns 400", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "   "}) |> json_response(400)
    end

    test "unknown stage id returns 404", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "x", stage: 999_999}) |> json_response(404)
    end

    test "uncastable stage id returns 404", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "x", stage: "not-a-number"}) |> json_response(404)
    end

    test "unauthenticated POST /api/cards returns 401" do
      build_conn() |> post(~p"/api/cards", %{title: "x"}) |> json_response(401)
    end
  end
  ```

- [x] Run the new tests and confirm they fail (no route yet):
  `mix test test/relay_web/api/card_controller_test.exs` — expect failures like
  `no route found for POST /api/cards`.

- [x] Add the route. In `lib/relay_web/router.ex`, inside the
  `scope "/api", RelayWeb.Api` block, add the `post "/cards"` line directly under the
  `get "/cards"` line so the collection routes sit together:

  ```elixir
    get "/cards", CardController, :index
    post "/cards", CardController, :create
    get "/cards/:ref", CardController, :show
  ```

- [x] Add the `create/2` action and its stage-resolution helper to
  `lib/relay_web/controllers/api/card_controller.ex`. Insert `create/2` directly after the
  `index/2` action (top of the module, near the other read/collection actions), and add the
  `resolve_create_stage/2` clauses just above the existing private `get_stage/2` helper so the
  two stage helpers live together:

  ```elixir
  def create(conn, params) do
    board = conn.assigns.current_board

    with {:ok, stage} <- resolve_create_stage(board, params["stage"]),
         {:ok, card} <- Cards.create_card(stage, params, :agent) do
      conn
      |> put_status(:created)
      |> render(:show, board: board, card: card, timeline: Activity.list_timeline(card))
    end
  end
  ```

  and, above `defp get_stage/2`:

  ```elixir
  # No stage given -> the board's first stage in position order (Backlog on
  # the default board). An explicit id that doesn't resolve is a 404 (get_stage
  # returns nil for uncastable or unknown ids).
  defp resolve_create_stage(board, nil) do
    case Boards.list_stages(board) do
      [stage | _] -> {:ok, stage}
      [] -> {:error, :invalid_request}
    end
  end

  defp resolve_create_stage(board, stage_id) do
    case get_stage(board, stage_id) do
      %Schemas.Stage{} = stage -> {:ok, stage}
      nil -> {:error, :not_found}
    end
  end
  ```

  Note: `Boards` and `Activity` are already aliased at the top of the module; no new aliases
  are needed.

- [x] Run the tests again and confirm they pass:
  `mix test test/relay_web/api/card_controller_test.exs` — all green.

- [x] Run `mix precommit` and fix any compile/format/credo/test failures.

**Deliverable:** `POST /api/cards` creates a card via the REST API — 201 with the standard
card shape on success (title-only → first stage; explicit valid stage honored), 400 on
missing/blank title, 404 on an unknown/uncastable stage, 401 unauthenticated — all covered by
tests.

**Commit message:** `feat(api): POST /api/cards to create a card`

---

## Task 2: `relay create` CLI command + docs

Add the `create` command to the live Python CLI (`bin/relay`) and document it in the CLI
reference table. `bin/relay` has no automated test harness in this repo (it is driven
manually), so this task's verification is running the argparse parser and a dry help check;
there is no ExUnit/pytest to write.

**Files**
- Modify: `bin/relay` (new `create_card(...)` helper, `cmd_create(...)` handler, argparse registration)
- Modify: `docs/agent-integration.md` (add a `relay create` row to the CLI reference table)

**Interfaces**

*Consumes* (existing helpers in `bin/relay`):
- `api(method, path, body=None)` — makes the authenticated request; raises/`die`s on HTTP error.
- `resolve_stage_id(name, board=None)` — stage name → id (via `GET /api/board`); `die`s if no such stage.
- `read_arg(text)` — resolves `-` (stdin) / `@path` (file) / literal; used by `describe`.
- `print_card(c)` and `emit(args, data, human)` — render a card struct to the console (or JSON with `--json`).
- The `POST /api/cards` endpoint from Task 1 (returns `{"data": {...card...}}`).

*Produces*:
- `create_card(title, stage_name=None, description=None, tag=None)` → the created card dict (the `"data"` payload).
- `relay create TITLE [--stage NAME] [--description TEXT] [--tag TAG] [--json]` subcommand.

**Steps**

- [x] Add the `create_card` helper to `bin/relay`, alongside the other board mutations
  (place it directly after the `move(...)` function, before `comment(...)`, in the
  "board mutations" section). It sends `stage` only when a name is given (server default
  otherwise), and `description`/`tag` only when provided:

  ```python
  def create_card(title, stage_name=None, description=None, tag=None):
      body = {"title": title}
      if stage_name is not None:
          body["stage"] = resolve_stage_id(stage_name)
      if description is not None:
          body["description"] = description
      if tag is not None:
          body["tag"] = tag
      return api("POST", "/api/cards", body)["data"]
  ```

- [x] Add the `cmd_create` handler to `bin/relay`, in the "CLI commands" section (place it
  after `cmd_card`, before `_simple`). `--description` honors `read_arg` (`@file` / `-`
  stdin), consistent with `describe`; on success it prints the card via `print_card`
  (or JSON with `--json`), like `card`:

  ```python
  def cmd_create(args):
      card = create_card(
          args.title,
          stage_name=args.stage,
          description=read_arg(args.description) if args.description is not None else None,
          tag=args.tag,
      )
      print(json.dumps(card, indent=2)) if args.json else print_card(card)
  ```

- [x] Register the `create` subcommand in `build_parser`. The shared `add(...)` helper only
  supports positional args + `--json`, so register `create` explicitly (like `watch` does),
  right after the `add("card", ...)` line:

  ```python
      c = add("create", cmd_create, "title", json_flag=True)
      c.add_argument("--stage")
      c.add_argument("--description")
      c.add_argument("--tag")
  ```

  (`add(...)` already adds the `title` positional, wires `--json`, and sets
  `func=cmd_create`; the three `add_argument` calls add the optional flags, which default to
  `None` when omitted — matching the `is not None` guards above.)

- [x] Verify the parser wiring without hitting the API. Run:
  `python3 bin/relay create --help`
  and confirm the usage line shows `create [--stage STAGE] [--description DESCRIPTION]
  [--tag TAG] [--json] title`. Also run `python3 -c "import ast; ast.parse(open('bin/relay').read())"`
  to confirm the file still parses.

- [x] (Optional, if `RELAY_URL`/`RELAY_API_KEY` are set to a running dev server) Smoke it
  end-to-end: `./bin/relay create "Smoke test card" --tag demo` should print the new card,
  and `./bin/relay board` should show it in the first stage. Skip if no server is available —
  Task 1's ExUnit tests already prove the endpoint.

- [x] Add a row to the CLI reference table in `docs/agent-integration.md`, directly under the
  `bin/relay card RLY-12` row (line ~37):

  ```
  | `bin/relay create "Fix login" --stage Backlog` | Create a new card (title; optional `--stage`/`--description`/`--tag`) |
  ```

- [x] Update the `bin/relay` module docstring usage summary (the `"""..."""` header near the
  top, around lines 13–19) to mention `create` so `--help`/the header stays accurate. Add it
  next to `describe`, e.g. change the `describe` usage line to include create:

  ```
    relay create TITLE [--stage N]  relay describe REF TEXT   relay needs-input REF Q
  ```

  (Keep the existing columns readable; the exact layout is cosmetic — just ensure `create`
  appears in the header.)

- [x] Run `mix precommit` to confirm nothing in the Elixir suite regressed (the CLI change is
  Python-only, but precommit is the project's required green gate).

**Deliverable:** `bin/relay create TITLE [--stage NAME] [--description TEXT] [--tag TAG]
[--json]` creates a card through the REST API and prints it; the command is documented in the
`docs/agent-integration.md` CLI reference table.

**Commit message:** `feat(cli): relay create command for POST /api/cards`
