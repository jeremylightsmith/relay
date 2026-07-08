# Plan: Create cards with the REST API (RLY-14)

## Goal
Add the missing **HTTP + CLI surface** for creating a card on the authenticated
board. The domain function `Relay.Cards.create_card/3` already does the hard part
(ref allocation, append-to-stage, `:created` activity log, live broadcast); this
work exposes it through:

1. `POST /api/cards` on the authenticated API.
2. A `create` command on the live Python CLI (`bin/relay`).
3. A parallel `create` command on the maintained Elixir CLI (`mix relay`).
4. A docs update (`docs/agent-integration.md` CLI reference table).

This unblocks bulk-loading work into Relay (the MMF dedup/import follow-up is a
separate card, out of scope here).

## Architecture
- **Web/API layer** (`RelayWeb.Api.CardController`): a new `create/2` action mirroring
  the existing `move/2` shape. It resolves the target stage (explicit `stage` id, or
  the board's first stage in position order when omitted), then calls
  `Cards.create_card/3` with the raw params and the `:agent` actor from `ApiAuth`.
  Errors flow through the existing `FallbackController` (`{:error, changeset}` → 400,
  `{:error, :not_found}` → 404). Success renders the shared `CardJSON.show` shape with
  `put_status(:created)`.
- **Elixir CLI** (`Relay.CLI` + `Mix.Tasks.Relay`): a `create/2` function following the
  `move/3` pattern (resolve a `--stage` *name* to an id via `GET /api/board`), wired
  into the mix task dispatch with `OptionParser` for the optional flags.
- **Python CLI** (`bin/relay`): a `create_card(...)` helper + `cmd_create` handler +
  argparse subcommand with optional `--stage/--description/--tag/--json` flags.

## Tech
Elixir/Phoenix (Phoenix v1.8, Ecto, `action_fallback`), `Req` + `Req.Test` for CLI
HTTP stubbing, Python 3 stdlib (`argparse`, `urllib`) for `bin/relay`.

## Global Constraints (from the spec + repo rules)
- Owners, status, and position are **not** settable at create time: a new card is
  `:queued`, unowned, appended to the bottom of its stage (whatever `create_card/3`
  does). A client that wants owners/status uses a follow-up `PATCH /api/cards/:ref`.
- The `:agent` actor and board come from `ApiAuth` (`conn.assigns.current_board`),
  exactly like the other card actions — never from request params.
- `create_card/3` already casts only `:title | :description | :tag` (via
  `Card.changeset/2`), so passing the raw string-keyed `params` map through is safe —
  `ref`, `stage`, etc. are ignored by the cast.
- `mix precommit` (compile warnings-as-errors, `mix format` with Styler, `credo
  --strict`, `sobelow`, `deps.audit`, full test suite) MUST pass before the work is
  done. Run it at the end of each task.
- Non-goals: bulk/batch create, MMF dedup/import, setting owners/status/position at
  create time, any new board UI.

---

## Task 1: `POST /api/cards` endpoint + controller action

Add the route and the `create/2` action (plus its `resolve_create_stage/2` helper,
reusing the controller's existing `get_stage/2`), and the full controller test suite.

**Files**
- Modify `lib/relay_web/router.ex` (add the route)
- Modify `lib/relay_web/controllers/api/card_controller.ex` (add `create/2` + helper)
- Modify `test/relay_web/api/card_controller_test.exs` (add a `POST /api/cards` describe block)

**Interfaces**
- **Consumes** (already exist, do not change):
  - `Relay.Cards.create_card(%Schemas.Stage{} = stage, attrs :: map, actor :: :agent | {:user, integer}) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}` — appends a `:queued`, unowned card, logs a `:created` activity, broadcasts. Returned card has `owners` preloaded.
  - `Relay.Boards.list_stages(%Schemas.Board{}) :: [%Schemas.Stage{}]` — stages in `position` order.
  - `Relay.Activity.list_timeline(%Schemas.Card{}) :: [entry]`.
  - Existing private helper in this controller: `get_stage(board, stage_id)` — integer or integer-string id → `%Schemas.Stage{}`; uncastable/unknown → `nil`.
  - `CardJSON.show/1` renders `%{data: card fields + :description + :timeline}`; `FallbackController` maps `{:error, %Ecto.Changeset{}}` → 400 `invalid` and `{:error, :not_found}` → 404 `not_found`.
- **Produces**:
  - Route `POST /api/cards` → `RelayWeb.Api.CardController.create/2`.
  - `RelayWeb.Api.CardController.create(conn, params)` — 201 on success, delegates errors to `FallbackController`.

**Steps**

- [x] Add the route. In `lib/relay_web/router.ex`, inside the `scope "/api", RelayWeb.Api` block, add the `create` route immediately after the `index` route:

  ```elixir
      get "/cards", CardController, :index
      post "/cards", CardController, :create
      get "/cards/:ref", CardController, :show
  ```

- [x] Write the failing controller tests. Append this `describe` block to
  `test/relay_web/api/card_controller_test.exs` (before the final `end` of the module).
  The existing `setup` provides `conn` (authenticated), `board`, and `stage` (a
  persisted "Spec" stage at position 1 on `board`):

  ```elixir
  describe "POST /api/cards" do
    test "creates a card with title only, landing in the board's first stage", %{conn: conn, board: board} do
      first = insert(:stage, board: board, name: "Backlog", owner: :human, position: 0)

      body =
        conn
        |> post(~p"/api/cards", %{title: "New card"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["title"] == "New card"
      assert body["status"] == "queued"
      assert body["stage_id"] == first.id
      assert body["owners"] == []
      assert Enum.any?(body["timeline"], &(&1["type"] == "created" and &1["author"]["name"] == "Relay AI"))
    end

    test "creates a card into an explicit stage id", %{conn: conn, stage: stage} do
      body =
        conn
        |> post(~p"/api/cards", %{title: "Placed", stage: stage.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == stage.id
    end

    test "accepts a stage id given as a string", %{conn: conn, stage: stage} do
      body =
        conn
        |> post(~p"/api/cards", %{title: "Placed", stage: to_string(stage.id)})
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["stage_id"] == stage.id
    end

    test "400 when title is missing", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{}) |> json_response(400)
    end

    test "400 when title is blank", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "   "}) |> json_response(400)
    end

    test "404 when the stage id is unknown", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "X", stage: 999_999}) |> json_response(404)
    end

    test "404 when the stage id is uncastable", %{conn: conn} do
      assert conn |> post(~p"/api/cards", %{title: "X", stage: "not-an-int"}) |> json_response(404)
    end

    test "created card appears in GET /api/cards", %{conn: conn} do
      conn |> post(~p"/api/cards", %{title: "Findable"}) |> json_response(201)

      titles =
        conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])

      assert "Findable" in titles
    end

    test "unauthenticated POST /api/cards is rejected", %{board: board} do
      insert(:stage, board: board, name: "Backlog", owner: :human, position: 0)

      assert build_conn() |> post(~p"/api/cards", %{title: "Nope"}) |> json_response(401)
    end
  end
  ```

- [x] Run the new tests and confirm they fail (no `create/2` action / route yet):
  `mix test test/relay_web/api/card_controller_test.exs`.

- [x] Implement `create/2`. In `lib/relay_web/controllers/api/card_controller.ex`, add
  the action after the existing `move/2` action (and before the `comments/2` clauses),
  reusing the existing `get_stage/2` helper further down the module:

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

  # No stage given -> the board's first stage in position order. An explicit
  # stage id reuses move/2's get_stage/2 (bad/unknown id -> nil -> not_found).
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

- [x] Run the tests again and confirm they pass:
  `mix test test/relay_web/api/card_controller_test.exs`.

- [x] Run `mix precommit` and fix any failures.

**Deliverable:** `POST /api/cards` creates a card (201, `CardJSON.show` shape) on the
authenticated board — first stage by default, explicit `stage` id honored — with 400 on
missing/blank title, 404 on an unknown/uncastable stage, and 401 unauthenticated. All
controller tests green; `mix precommit` passes.

**Commit:** `feat(api): POST /api/cards to create a card (RLY-14)`

---

## Task 2: `mix relay create` (Elixir CLI)

Add a `create` command to the maintained Elixir CLI, matching the `move`/`status`
conventions: `Relay.CLI.create/2` (resolves an optional `--stage` *name* to an id via
`GET /api/board`, like `move/3`) wired into the mix task with `OptionParser`.

**Files**
- Modify `lib/relay/cli.ex` (add `create/2` + a `put_if/3` helper)
- Modify `lib/mix/tasks/relay.ex` (dispatch `create` + usage line)
- Modify `test/relay/cli_test.exs` (add create tests)

**Interfaces**
- **Consumes**:
  - `Relay.CLI.request(method, path, body \\ nil)` — authenticated `Req` call, returns `{:ok, decoded}` or `{:error, message}`.
  - `Relay.CLI.render(opts, data, human)` — pretty JSON when `opts[:json]`, else `human`.
  - `Relay.CLI.format_card_line(card)` (private) — the one-line card summary.
  - `POST /api/cards` and `GET /api/board` from the running API (stubbed via `Req.Test` in tests).
- **Produces**:
  - `Relay.CLI.create(title :: String.t(), opts :: keyword) :: {:ok, String.t()} | {:error, String.t()}` — `opts` may include `:stage` (a stage *name*), `:description`, `:tag`, `:json`.
  - Mix dispatch: `mix relay create TITLE [--stage NAME] [--description TEXT] [--tag TAG] [--json]`.

**Steps**

- [x] Write the failing CLI tests. Append these to `test/relay/cli_test.exs` (before the
  module's final `end`). They use the file's existing `stub/1` helper (`Req.Test.stub`):

  ```elixir
  test "create posts a new card with title only" do
    stub(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/cards"
      assert conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!() == %{"title" => "New one"}

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "data" => %{
          "ref" => "RLY-5",
          "title" => "New one",
          "status" => "queued",
          "stage_id" => 1,
          "active_owner" => nil,
          "owners" => []
        }
      })
    end)

    assert {:ok, text} = CLI.create("New one", [])
    assert text =~ "RLY-5"
  end

  test "create includes description and tag when given" do
    stub(fn conn ->
      body = conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!()
      assert body == %{"title" => "T", "description" => "details", "tag" => "chore"}

      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "data" => %{
          "ref" => "RLY-7",
          "title" => "T",
          "status" => "queued",
          "stage_id" => 1,
          "active_owner" => nil,
          "owners" => []
        }
      })
    end)

    assert {:ok, text} = CLI.create("T", description: "details", tag: "chore")
    assert text =~ "RLY-7"
  end

  test "create resolves --stage name to an id then posts" do
    stub(fn conn ->
      case conn.request_path do
        "/api/board" ->
          Req.Test.json(conn, %{
            "board" => %{"name" => "B", "key" => "RLY"},
            "stages" => [
              %{"id" => 3, "name" => "Backlog", "owner" => "human", "category" => "unstarted", "position" => 1}
            ],
            "cards" => []
          })

        "/api/cards" ->
          assert conn |> Plug.Conn.read_body() |> elem(1) |> Jason.decode!() |> Access.get("stage") == 3

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "data" => %{
              "ref" => "RLY-6",
              "title" => "Placed",
              "status" => "queued",
              "stage_id" => 3,
              "active_owner" => nil,
              "owners" => []
            }
          })
      end
    end)

    assert {:ok, text} = CLI.create("Placed", stage: "Backlog")
    assert text =~ "RLY-6"
  end

  test "create errors when the --stage name is unknown" do
    stub(fn conn ->
      Req.Test.json(conn, %{"board" => %{"name" => "B", "key" => "RLY"}, "stages" => [], "cards" => []})
    end)

    assert {:error, msg} = CLI.create("X", stage: "Nope")
    assert msg =~ "Nope"
  end
  ```

- [x] Run the new tests and confirm they fail (no `create/2` yet):
  `mix test test/relay/cli_test.exs`.

- [x] Implement `Relay.CLI.create/2`. In `lib/relay/cli.ex`, add the function after
  `move/3` (keep `defp env`, `defp send_request`, etc. below it), and add the `put_if/3`
  helper alongside the other private helpers:

  ```elixir
  @doc """
  Creates a card with `title`. Optional `opts`: `:stage` (a stage *name*,
  resolved to its id on the board), `:description`, `:tag`. Owners/status are
  not settable here (a new card is queued and unowned).
  """
  def create(title, opts) do
    with {:ok, body} <- create_body(title, opts),
         {:ok, %{"data" => card}} <- request(:post, "/api/cards", body) do
      {:ok, render(opts, card, format_card_line(card))}
    end
  end

  defp create_body(title, opts) do
    base =
      %{title: title}
      |> put_if(:description, opts[:description])
      |> put_if(:tag, opts[:tag])

    case opts[:stage] do
      nil ->
        {:ok, base}

      stage_name ->
        with {:ok, board} <- request(:get, "/api/board"),
             %{"id" => id} <-
               Enum.find(board["stages"], &(&1["name"] == stage_name)) || {:no_stage, stage_name} do
          {:ok, Map.put(base, :stage, id)}
        else
          {:no_stage, name} -> {:error, "no stage named #{inspect(name)} on this board"}
          other -> other
        end
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  ```

- [x] Wire it into the mix task. In `lib/mix/tasks/relay.ex`, add a `create` dispatch
  clause (before the catch-all `dispatch(_argv, _opts)` clause). It parses the optional
  flags with `OptionParser` and merges them into `opts`:

  ```elixir
  defp dispatch(["create" | rest], opts) do
    {flags, positional, _invalid} =
      OptionParser.parse(rest, strict: [stage: :string, description: :string, tag: :string])

    case positional do
      [title] -> Relay.CLI.create(title, Keyword.merge(opts, flags))
      _ -> {:error, usage()}
    end
  end
  ```

  And add a line to the `usage/0` heredoc, aligned with the existing entries (just after
  the `status REF STATUS` line):

  ```
      create "Title" [--stage N] create a card (first stage unless --stage)
  ```

- [x] Run the tests again and confirm they pass:
  `mix test test/relay/cli_test.exs`.

- [x] Run `mix precommit` and fix any failures.

**Deliverable:** `mix relay create "Title" [--stage NAME] [--description TEXT] [--tag TAG]
[--json]` creates a card via the API and prints the one-line card summary (or JSON with
`--json`); an unknown `--stage` name errors before any create. CLI tests green;
`mix precommit` passes.

**Commit:** `feat(cli): mix relay create command (RLY-14)`

---

## Task 3: `bin/relay create` (Python CLI) + docs

Add the `create` command to the live Python CLI and update the docs CLI reference table.
The Python script has no unit-test harness in this repo, so it is verified with
`py_compile` (syntax) and `--help` (argparse wiring).

**Files**
- Modify `bin/relay` (helper, command handler, argparse registration, docstring)
- Modify `docs/agent-integration.md` (CLI reference table)

**Interfaces**
- **Consumes** (existing in `bin/relay`):
  - `api(method, path, body=None)` — authenticated request; returns decoded JSON.
  - `resolve_stage_id(name, board=None)` — stage *name* → id (dies if not found).
  - `read_arg(text)` — `-` (stdin) / `@path` (file) / literal passthrough.
  - `print_card(c)` — human render of a card.
  - `add(name, fn, *pos, json_flag=False)` — registers a subcommand and **returns** the
    subparser (so optional flags can be attached).
- **Produces**:
  - `create_card(title, stage=None, description=None, tag=None)` — returns the created
    card dict (`api("POST", "/api/cards", body)["data"]`), including `stage` in the body
    only when a stage name is given.
  - `cmd_create(args)` — CLI handler; prints via `print_card` or JSON with `--json`.
  - Subcommand: `relay create TITLE [--stage NAME] [--description TEXT] [--tag TAG] [--json]`.

**Steps**

- [ ] Add the `create_card` helper. In `bin/relay`, in the "board mutations" group
  (after the existing `needs_input` function, ~line 129):

  ```python
  def create_card(title, stage=None, description=None, tag=None):
      body = {"title": title}
      if stage is not None:
          body["stage"] = resolve_stage_id(stage)
      if description is not None:
          body["description"] = description
      if tag is not None:
          body["tag"] = tag
      return api("POST", "/api/cards", body)["data"]
  ```

- [ ] Add the `cmd_create` handler. In the "CLI commands" group (near `cmd_card`,
  ~line 173), add:

  ```python
  def cmd_create(args):
      card = create_card(
          args.title,
          stage=args.stage,
          description=read_arg(args.description) if args.description else None,
          tag=args.tag,
      )
      print(json.dumps(card, indent=2)) if args.json else print_card(card)
  ```

- [ ] Register the subcommand. In `build_parser()`, after the `add("card", ...)` line,
  add (capturing the returned subparser to attach the optional flags):

  ```python
      cr = add("create", cmd_create, "title", json_flag=True)
      cr.add_argument("--stage")
      cr.add_argument("--description")
      cr.add_argument("--tag")
  ```

- [ ] Update the top-of-file usage docstring. In the command listing block (the lines
  around `relay board [--json] ...`), add a `create` line so `relay --help`/the header
  documents it. Place it just above the `relay comment ... relay move ...` line:

  ```
    relay create TITLE [--stage NAME] [--description TEXT] [--tag TAG]
  ```

- [ ] Verify the script compiles and the subcommand is wired:
  - `python3 -m py_compile bin/relay` (exit 0, no syntax error).
  - `python3 bin/relay create --help` (exit 0; prints usage showing `title`, `--stage`,
    `--description`, `--tag`, `--json`).

- [ ] Update the docs CLI reference table. In `docs/agent-integration.md`, add a row to
  the `| Command | What it does |` table (right after the `card` row, so create sits
  near the read commands):

  ```markdown
  | `mix relay create "New card" --stage Backlog` | Create a card (lands in the first stage unless `--stage`) |
  ```

- [ ] Run `mix precommit` and fix any failures (the Python + Markdown changes should not
  affect it, but confirm the suite is still green).

**Deliverable:** `bin/relay create "Title" [--stage NAME] [--description TEXT] [--tag TAG]
[--json]` creates a card through the API and prints it (JSON with `--json`); `--stage`
resolves a stage name to its id (server default when omitted); `--description` honors
`@file`/`-` stdin. `bin/relay create --help` shows the flags; `py_compile` is clean; the
docs table documents the command; `mix precommit` passes.

**Commit:** `feat(cli): bin/relay create + docs (RLY-14)`
