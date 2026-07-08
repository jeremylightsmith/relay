# Plan — MMF 09: Relay REST API

**Spec:** `docs/superpowers/specs/2026-07-07-rest-api-design.md`

## Goal

Make Relay programmable: a Bearer-authenticated JSON API, scoped to the board its key belongs
to, that reads the board and drives cards (update/move/comment/needs-input/owners/status) — all
**thin over the existing `Relay.Cards` / `Relay.Boards` / `Relay.Activity` contexts** with no
logic fork. All writes are attributed to the `:agent` actor so they render as "Relay AI" in the
timeline.

## Architecture

- **Auth:** a `RelayWeb.ApiAuth` plug reads `Authorization: Bearer relay_<prefix>_<secret>`,
  calls `Relay.ApiKeys.authenticate/1`, and on success assigns `conn.assigns.current_board` +
  `conn.assigns.actor = :agent`. Any missing/malformed/invalid/revoked token → **401 JSON** and
  `halt`. Runs as an `:api_auth` pipeline after the existing `:api` pipeline.
- **Routing:** `scope "/api", RelayWeb.Api` → `BoardController` (board read) + `CardController`
  (card read/write/actions).
- **Errors:** `action_fallback RelayWeb.Api.FallbackController` turns `{:error, :not_found}` →
  404 and `{:error, %Ecto.Changeset{}}` → 400, both rendered by `RelayWeb.Api.ErrorJSON` as
  `{"error": {"code", "message"}}`.
- **JSON views:** `RelayWeb.Api.BoardJSON` and `RelayWeb.Api.CardJSON` (Phoenix derives the view
  from the controller name). `CardJSON.data/2` is the shared card shape reused everywhere.

## Tech

Phoenix 1.8 controllers/JSON views, Ecto, `Jason`. No new deps.

## Global Constraints (project-wide — verbatim intent from AGENTS.md + spec)

- `mix precommit` MUST pass before any task is done (compile warnings-as-errors, `mix format`
  with Styler, `mix credo --strict`, `mix sobelow`, `mix deps.audit`, full test suite).
- **Boundaries are enforced by the compiler.** `RelayWeb` may only call the domain through
  `Relay`'s exported contexts (`Relay.Cards`, `Relay.Boards`, `Relay.Activity`, `Relay.ApiKeys`)
  and may use `Schemas.*`. Controllers/plugs/views must NOT call `Relay.Repo` or reach into a
  context's internals. A violation fails compilation.
- Never call `String.to_atom/1` on user input. Parsing owner/status strings uses fixed literal
  matches or `String.to_integer/1`, never dynamic atoms.
- Programmatic fields are never cast from params — persistence goes through the context
  functions, which already guard this.
- Elixir lists: no index access via `list[i]`; use `Enum`/pattern matching.
- Reuse the same contexts as the LiveView — do not duplicate domain logic in the web layer.

## Interfaces available from earlier MMFs (Consumes — exact signatures)

- `Relay.ApiKeys.authenticate(raw_token :: binary) :: {:ok, %Schemas.Board{}} | :error`
- `Relay.Cards.list_cards(%Schemas.Board{}) :: [%Schemas.Card{}]` (owners preloaded)
- `Relay.Cards.get_card_by_ref(%Schemas.Board{}, ref :: binary) :: %Schemas.Card{} | nil` (owners preloaded; board-scoped)
- `Relay.Cards.ref(%Schemas.Board{}, %Schemas.Card{}) :: binary` (e.g. `"RLY-12"`)
- `Relay.Cards.update_card(%Schemas.Card{}, attrs) :: {:ok, card} | {:error, changeset}` (casts `:title`,`:description`,`:tag`)
- `Relay.Cards.set_status(%Schemas.Card{}, attrs, actor \\ :agent) :: {:ok, card} | {:error, changeset}` (attrs `%{status:, progress:}`)
- `Relay.Cards.set_owners(%Schemas.Card{}, actors :: [actor], actor \\ :agent) :: {:ok, card} | {:error, changeset}`
- `Relay.Cards.move_card(%Schemas.Card{}, %Schemas.Stage{}, index :: integer, actor \\ :agent) :: {:ok, card} | {:error, changeset}` (0-based index, clamped)
- `Relay.Cards.active_owner_type(%{owners: list}) :: :ai | :human | nil`
- `Relay.Activity.add_comment(%Schemas.Card{}, %{actor: actor, body: binary}) :: {:ok, %Schemas.Comment{}} | {:error, changeset}` (author preloaded)
- `Relay.Activity.list_timeline(%Schemas.Card{}) :: [%Schemas.Comment{} | %Schemas.Activity{}]` (`:user` preloaded, chronological)
- **actor** type = `:agent | {:user, user_id :: integer}`
- Test helpers: `Relay.Factory` (`insert(:board)` persists its `owner` user; `insert(:stage, board: board)`; `insert(:card, stage: stage)`), `Relay.ApiKeys.create_key(board, creator) :: {:ok, %{api_key:, token:}}`.

---

## Task 1: API auth + routing/error scaffolding + `GET /api/board`

The foundation slice: authenticate a Bearer key to a board, wire the `/api` scope + JSON error
handling, add the two `Boards` read helpers the API needs, and ship the first read endpoint with
the shared card JSON shape.

**Files**
- create `lib/relay_web/api_auth.ex` — `RelayWeb.ApiAuth` plug
- create `lib/relay_web/controllers/api/fallback_controller.ex` — `RelayWeb.Api.FallbackController`
- create `lib/relay_web/controllers/api/error_json.ex` — `RelayWeb.Api.ErrorJSON`
- create `lib/relay_web/controllers/api/board_controller.ex` — `RelayWeb.Api.BoardController`
- create `lib/relay_web/controllers/api/board_json.ex` — `RelayWeb.Api.BoardJSON`
- create `lib/relay_web/controllers/api/card_controller.ex` — `RelayWeb.Api.CardController` (empty shell here; actions in Tasks 2–3)
- create `lib/relay_web/controllers/api/card_json.ex` — `RelayWeb.Api.CardJSON` (shared `data/2` + `stage/1`; extended in Task 2)
- modify `lib/relay_web/router.ex` — `:api_auth` pipeline + `/api` scope
- modify `lib/relay/boards.ex` — add `list_stages/1` and `get_stage/2`
- create `test/relay_web/api/api_auth_test.exs`
- create `test/relay_web/api/board_controller_test.exs`
- create `test/relay/boards_stage_lookup_test.exs`

**Interfaces**
- *Consumes:* `Relay.ApiKeys.authenticate/1`, `Relay.Cards.list_cards/1`, `Relay.Cards.ref/2`, `Relay.Cards.active_owner_type/1`.
- *Produces:*
  - `Relay.Boards.list_stages(%Schemas.Board{}) :: [%Schemas.Stage{}]` (position order)
  - `Relay.Boards.get_stage(%Schemas.Board{}, id) :: %Schemas.Stage{} | nil` (board-scoped)
  - `RelayWeb.ApiAuth` plug → assigns `:current_board`, `:actor`
  - `RelayWeb.Api.CardJSON.data(board, card) :: map`, `RelayWeb.Api.CardJSON.stage(stage) :: map`
  - `RelayWeb.Api.ErrorJSON.error(%{code:, message:}) :: map`

### Steps

- [x] **Boards read helpers — failing test.** Add `test/relay/boards_stage_lookup_test.exs`:

```elixir
defmodule Relay.BoardsStageLookupTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  describe "list_stages/1" do
    test "returns the board's stages in position order" do
      board = insert(:board)
      insert(:stage, board: board, name: "Two", position: 2)
      insert(:stage, board: board, name: "One", position: 1)
      _other = insert(:stage, name: "Foreign", position: 1)

      names = board |> Boards.list_stages() |> Enum.map(& &1.name)
      assert names == ["One", "Two"]
    end
  end

  describe "get_stage/2" do
    test "returns a stage on the board, nil for another board's stage" do
      board = insert(:board)
      stage = insert(:stage, board: board)
      foreign = insert(:stage)

      assert %Schemas.Stage{id: id} = Boards.get_stage(board, stage.id)
      assert id == stage.id
      assert Boards.get_stage(board, foreign.id) == nil
      assert Boards.get_stage(board, -1) == nil
    end
  end
end
```

- [x] **Run it — expect fail** (`mix test test/relay/boards_stage_lookup_test.exs`): `list_stages/1` and `get_stage/2` are undefined.

- [x] **Implement the helpers.** In `lib/relay/boards.ex`, add inside the module (public, after `get_or_create_default_board/1`):

```elixir
  @doc "Returns the board's stages in position order."
  def list_stages(%Board{id: board_id}) do
    Repo.all(from s in Stage, where: s.board_id == ^board_id, order_by: s.position)
  end

  @doc "Returns the stage with `id` on `board`, or nil (board-scoped lookup)."
  def get_stage(%Board{id: board_id}, id) do
    Repo.get_by(Stage, id: id, board_id: board_id)
  end
```

- [x] **Run it — expect pass.**

- [x] **Auth plug — failing test.** Add `test/relay_web/api/api_auth_test.exs`:

```elixir
defmodule RelayWeb.ApiAuthTest do
  use RelayWeb.ConnCase, async: true

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "valid key authenticates and reaches the board endpoint", %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)

    conn = conn |> auth(token) |> get(~p"/api/board")
    assert json_response(conn, 200)["board"]["key"] == board.key
  end

  test "missing key returns 401", %{conn: conn} do
    conn = get(conn, ~p"/api/board")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "malformed / unknown / revoked key returns 401", %{conn: conn} do
    board = insert(:board)
    {:ok, %{api_key: key, token: token}} = Relay.ApiKeys.create_key(board, board.owner)

    assert conn |> auth("garbage") |> get(~p"/api/board") |> json_response(401)
    assert conn |> auth("relay_deadbeef_nope") |> get(~p"/api/board") |> json_response(401)

    {:ok, _} = Relay.ApiKeys.revoke(key)
    assert conn |> auth(token) |> get(~p"/api/board") |> json_response(401)
  end
end
```

- [x] **Run it — expect fail** (route/plug/controller undefined).

- [x] **Implement the plug.** Create `lib/relay_web/api_auth.ex`:

```elixir
defmodule RelayWeb.ApiAuth do
  @moduledoc """
  Authenticates JSON API requests by `Authorization: Bearer <board key>`.
  On success assigns `:current_board` and the `:agent` actor; otherwise
  responds 401 JSON and halts. See MMF 09.
  """

  import Plug.Conn

  alias Relay.ApiKeys

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, board} <- ApiKeys.authenticate(token) do
      conn
      |> assign(:current_board, board)
      |> assign(:actor, :agent)
    else
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    body = Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or missing API key"}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
```

- [x] **Implement the error scaffolding.** Create `lib/relay_web/controllers/api/error_json.ex`:

```elixir
defmodule RelayWeb.Api.ErrorJSON do
  @moduledoc "Renders the API's consistent error shape."

  def error(%{code: code, message: message}) do
    %{error: %{code: code, message: message}}
  end
end
```

Create `lib/relay_web/controllers/api/fallback_controller.ex`:

```elixir
defmodule RelayWeb.Api.FallbackController do
  @moduledoc "Maps context error tuples to JSON error responses."
  use RelayWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: RelayWeb.Api.ErrorJSON)
    |> render(:error, code: "not_found", message: "Not found")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: RelayWeb.Api.ErrorJSON)
    |> render(:error, code: "invalid", message: changeset_message(changeset))
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
```

- [x] **Implement the shared card JSON.** Create `lib/relay_web/controllers/api/card_json.ex`:

```elixir
defmodule RelayWeb.Api.CardJSON do
  @moduledoc "JSON representation of cards (shared across API controllers)."

  alias Relay.Cards

  @doc "The shared card shape. `board` supplies the ref + key."
  def data(board, card) do
    %{
      id: card.id,
      ref: Cards.ref(board, card),
      title: card.title,
      tag: card.tag,
      status: card.status,
      progress: card.progress,
      stage_id: card.stage_id,
      owners: Enum.map(card.owners, &owner/1),
      active_owner: Cards.active_owner_type(card)
    }
  end

  @doc "The shared stage shape."
  def stage(stage) do
    %{id: stage.id, name: stage.name, category: stage.category, owner: stage.owner, position: stage.position}
  end

  defp owner(%Schemas.CardOwner{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}

  defp owner(%Schemas.CardOwner{actor_type: :user, user: user}) do
    %{type: "user", id: user.id, name: user.name || user.email}
  end
end
```

- [x] **Implement the board endpoint.** Create `lib/relay_web/controllers/api/board_controller.ex`:

```elixir
defmodule RelayWeb.Api.BoardController do
  use RelayWeb, :controller

  alias Relay.Boards
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController

  def show(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :show, board: board, stages: Boards.list_stages(board), cards: Cards.list_cards(board))
  end
end
```

Create `lib/relay_web/controllers/api/board_json.ex`:

```elixir
defmodule RelayWeb.Api.BoardJSON do
  alias RelayWeb.Api.CardJSON

  def show(%{board: board, stages: stages, cards: cards}) do
    %{
      board: %{id: board.id, name: board.name, key: board.key},
      stages: Enum.map(stages, &CardJSON.stage/1),
      cards: Enum.map(cards, &CardJSON.data(board, &1))
    }
  end
end
```

- [x] **Create the empty card controller shell** so the router's `CardController` routes compile (actions arrive in Tasks 2–3). Create `lib/relay_web/controllers/api/card_controller.ex`:

```elixir
defmodule RelayWeb.Api.CardController do
  use RelayWeb, :controller

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController
end
```

(The unused aliases are added by Tasks 2–3; if compile warns-as-errors on them now, omit the alias lines here and add them with their first use.)

- [x] **Wire the router.** In `lib/relay_web/router.ex`, add after the `:api` pipeline (and remove the commented-out `# scope "/api"` sample):

```elixir
  pipeline :api_auth do
    plug RelayWeb.ApiAuth
  end

  scope "/api", RelayWeb.Api do
    pipe_through [:api, :api_auth]

    get "/board", BoardController, :show
    get "/cards", CardController, :index
    get "/cards/:ref", CardController, :show
    patch "/cards/:ref", CardController, :update
    post "/cards/:ref/move", CardController, :move
    post "/cards/:ref/comments", CardController, :comments
    post "/cards/:ref/needs-input", CardController, :needs_input
  end
```

- [x] **Board endpoint — failing test.** Add `test/relay_web/api/board_controller_test.exs`:

```elixir
defmodule RelayWeb.Api.BoardControllerTest do
  use RelayWeb.ConnCase, async: true

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), board: board}
  end

  test "returns the key's board with stages and cards (status + owners)", %{conn: conn, board: board} do
    stage = insert(:stage, board: board, name: "Plan", owner: :ai, position: 1)
    card = insert(:card, stage: stage, title: "Ship it", status: :working, progress: 40)
    insert(:card_owner, card: card)

    other = insert(:board)
    insert(:card, stage: insert(:stage, board: other))

    body = conn |> get(~p"/api/board") |> json_response(200)

    assert body["board"]["key"] == board.key
    assert Enum.any?(body["stages"], &(&1["name"] == "Plan" and &1["owner"] == "ai"))

    assert [card_json] = body["cards"]
    assert card_json["title"] == "Ship it"
    assert card_json["status"] == "working"
    assert card_json["active_owner"] == "ai"
    assert [%{"type" => "agent"}] = card_json["owners"]
  end
end
```

- [x] **Run it — expect pass.**

- [x] **Full check + commit.** Run `mix precommit`. Commit: `feat(api): Bearer auth + GET /api/board (scoped board read)`.

**Deliverable:** a Bearer-authenticated `GET /api/board` that returns only the key's board with stages and cards (status + owners); bad/missing keys → 401 JSON; `Boards.list_stages/1`+`get_stage/2` and the shared JSON scaffolding exist for the next tasks.

---

## Task 2: Card read + update — `GET /api/cards`, `GET /api/cards/:ref`, `PATCH /api/cards/:ref`

Reading cards and the timeline, and the write path the agent uses to edit fields, set status, and
claim/release ownership.

**Files**
- modify `lib/relay_web/controllers/api/card_controller.ex` — `index/2`, `show/2`, `update/2`
- modify `lib/relay_web/controllers/api/card_json.ex` — add `index/1`, `show/1`, timeline entries
- create `test/relay_web/api/card_controller_test.exs`

**Interfaces**
- *Consumes:* `Relay.Cards.list_cards/1`, `get_card_by_ref/2`, `update_card/2`, `set_status/3`, `set_owners/3`, `Relay.Activity.list_timeline/1`, `RelayWeb.Api.CardJSON.data/2`.
- *Produces:* `RelayWeb.Api.CardJSON.index/1`, `RelayWeb.Api.CardJSON.show/1`; `CardController.index/2`, `show/2`, `update/2`.

### Steps

- [ ] **Failing tests.** Add `test/relay_web/api/card_controller_test.exs`:

```elixir
defmodule RelayWeb.Api.CardControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    stage = insert(:stage, board: board, name: "Spec", owner: :human, position: 1)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, stage: stage}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "GET /api/cards lists the board's cards", %{conn: conn, stage: stage} do
    insert(:card, stage: stage, title: "A")
    insert(:card, stage: stage, title: "B")

    titles = conn |> get(~p"/api/cards") |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["title"])
    assert "A" in titles and "B" in titles
  end

  test "GET /api/cards/:ref returns the card with its timeline", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Read me", description: "details")
    {:ok, _} = Activity.add_comment(card, %{actor: :agent, body: "hello from AI"})

    body = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert body["title"] == "Read me"
    assert body["description"] == "details"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["author"]["name"] == "Relay AI"))
  end

  test "unknown ref and another board's ref both 404", %{conn: conn, board: board} do
    other_card = insert(:card, stage: insert(:stage, board: insert(:board)))

    assert conn |> get(~p"/api/cards/RLY-9999") |> json_response(404)
    assert conn |> get(~p"/api/cards/#{ref(board, other_card)}") |> json_response(404)
  end

  test "PATCH updates title and status", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Old")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{title: "New", status: "in_review"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["title"] == "New"
    assert body["status"] == "in_review"
  end

  test "PATCH owners claims for AI then hands back to a user", %{conn: conn, board: board, stage: stage} do
    user = insert(:user)
    card = insert(:card, stage: stage)

    ai = conn |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["agent"]}) |> json_response(200) |> Map.fetch!("data")
    assert ai["active_owner"] == "ai"

    human =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{owners: ["user:#{user.id}"]})
      |> json_response(200)
      |> Map.fetch!("data")

    assert human["active_owner"] == "human"
    assert [%{"type" => "user", "id" => id}] = human["owners"]
    assert id == user.id
  end

  test "PATCH invalid status returns 400", %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage)
    assert conn |> patch(~p"/api/cards/#{ref(board, card)}", %{status: "bogus"}) |> json_response(400)
  end
end
```

- [ ] **Run — expect fail** (actions/renders undefined).

- [ ] **Implement the controller actions.** Set `lib/relay_web/controllers/api/card_controller.ex` to:

```elixir
defmodule RelayWeb.Api.CardController do
  use RelayWeb, :controller

  alias Relay.Activity
  alias Relay.Cards

  action_fallback RelayWeb.Api.FallbackController

  def index(conn, _params) do
    board = conn.assigns.current_board
    render(conn, :index, board: board, cards: Cards.list_cards(board))
  end

  def show(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
    end
  end

  def update(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- update_fields(card, params),
         {:ok, card} <- update_status(card, params),
         {:ok, card} <- update_owners(card, params) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp update_fields(card, params) do
    case Map.take(params, ["title", "description", "tag"]) do
      empty when map_size(empty) == 0 -> {:ok, card}
      fields -> Cards.update_card(card, fields)
    end
  end

  defp update_status(card, %{"status" => status} = params) do
    attrs = params |> Map.take(["progress"]) |> Map.put("status", status)
    Cards.set_status(card, attrs, :agent)
  end

  defp update_status(card, _params), do: {:ok, card}

  defp update_owners(card, %{"owners" => owners}) when is_list(owners) do
    Cards.set_owners(card, Enum.map(owners, &parse_actor/1), :agent)
  end

  defp update_owners(card, _params), do: {:ok, card}

  defp parse_actor("agent"), do: :agent
  defp parse_actor("user:" <> id), do: {:user, String.to_integer(id)}
end
```

- [ ] **Implement the JSON renders.** Add to `lib/relay_web/controllers/api/card_json.ex`:

```elixir
  def index(%{board: board, cards: cards}) do
    %{data: Enum.map(cards, &data(board, &1))}
  end

  def show(%{board: board, card: card, timeline: timeline}) do
    %{
      data:
        board
        |> data(card)
        |> Map.put(:description, card.description)
        |> Map.put(:timeline, Enum.map(timeline, &entry/1))
    }
  end

  defp entry(%Schemas.Comment{} = c) do
    %{kind: "comment", body: c.body, author: author(c), inserted_at: c.inserted_at}
  end

  defp entry(%Schemas.Activity{} = a) do
    %{kind: "activity", type: a.type, meta: a.meta, author: author(a), inserted_at: a.inserted_at}
  end

  defp author(%{actor_type: :agent}), do: %{type: "agent", name: "Relay AI"}
  defp author(%{actor_type: :user, user: user}), do: %{type: "user", id: user.id, name: user.name || user.email}
```

- [ ] **Run — expect pass.**

- [ ] **Full check + commit.** `mix precommit`. Commit: `feat(api): GET /api/cards, GET/PATCH /api/cards/:ref (fields, status, owners)`.

**Deliverable:** list/read cards with timeline; PATCH persists title/description/tag, status (400 on invalid), and owners (claim `["agent"]` → AI active, hand back `["user:ID"]` → human active); unknown/foreign refs → 404 — all attributed to the agent.

---

## Task 3: Card actions — `POST .../move`, `.../comments`, `.../needs-input`

The remaining agent verbs: move a card between stages, comment as the agent, and flag
needs-input with a question.

**Files**
- modify `lib/relay_web/controllers/api/card_controller.ex` — `move/2`, `comments/2`, `needs_input/2` (+ `alias Relay.Boards`)
- modify `lib/relay_web/controllers/api/card_json.ex` — add `comment/1`
- create `test/relay_web/api/card_actions_test.exs`

**Interfaces**
- *Consumes:* `Relay.Cards.get_card_by_ref/2`, `move_card/4`, `set_status/3`, `Relay.Boards.get_stage/2`, `Relay.Activity.add_comment/2`, `list_timeline/1`.
- *Produces:* `CardController.move/2`, `comments/2`, `needs_input/2`; `CardJSON.comment/1`.

### Steps

- [ ] **Failing tests.** Add `test/relay_web/api/card_actions_test.exs`:

```elixir
defmodule RelayWeb.Api.CardActionsTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    spec = insert(:stage, board: board, name: "Spec", position: 1)
    code = insert(:stage, board: board, name: "Code", owner: :ai, position: 2)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, spec: spec, code: code}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "move sets the card's stage and logs a moved entry as the agent", %{conn: conn, board: board, spec: spec, code: code} do
    card = insert(:card, stage: spec)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/move", %{stage: code.id})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["stage_id"] == code.id
    assert Cards.get_card_by_ref(board, ref(board, card)).stage_id == code.id

    moved = Activity.list_timeline(%Schemas.Card{id: card.id})
    assert Enum.any?(moved, &(Map.get(&1, :type) == :moved and &1.actor_type == :agent))
  end

  test "move to a stage on another board 404s", %{conn: conn, board: board, spec: spec} do
    foreign_stage = insert(:stage, board: insert(:board))
    card = insert(:card, stage: spec)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/move", %{stage: foreign_stage.id}) |> json_response(404)
  end

  test "comments posts an agent comment shown as Relay AI", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    body = conn |> post(~p"/api/cards/#{ref(board, card)}/comments", %{body: "on it"}) |> json_response(201)
    assert body["data"]["body"] == "on it"
    assert body["data"]["author"]["name"] == "Relay AI"
  end

  test "needs-input sets status and records the question", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{question: "Which region?"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "needs_input"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["body"] == "Which region?"))
  end

  test "actions on an unknown ref 404", %{conn: conn} do
    assert conn |> post(~p"/api/cards/RLY-9999/comments", %{body: "x"}) |> json_response(404)
  end
end
```

- [ ] **Run — expect fail.**

- [ ] **Implement the actions.** Add `alias Relay.Boards` to `RelayWeb.Api.CardController` and add these functions:

```elixir
  def move(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         %Schemas.Stage{} = stage <- Boards.get_stage(board, params["stage"]),
         {:ok, card} <- Cards.move_card(card, stage, move_index(params), :agent) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def comments(conn, %{"ref" => ref, "body" => body}) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, comment} <- Activity.add_comment(card, %{actor: :agent, body: body}) do
      conn |> put_status(:created) |> render(:comment, comment: comment)
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def needs_input(conn, %{"ref" => ref, "question" => question}) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.set_status(card, %{status: :needs_input}, :agent),
         {:ok, _comment} <- Activity.add_comment(card, %{actor: :agent, body: question}) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # 1-based `position` from the API maps to move_card's 0-based index; a
  # missing position appends (move_card clamps a large index to the end).
  defp move_index(%{"position" => p}) when is_integer(p), do: p - 1
  defp move_index(%{"position" => p}) when is_binary(p), do: String.to_integer(p) - 1
  defp move_index(_params), do: 1_000_000
```

- [ ] **Implement the comment render.** Add to `lib/relay_web/controllers/api/card_json.ex`:

```elixir
  def comment(%{comment: comment}) do
    %{data: entry(comment)}
  end
```

(`entry/1` + `author/1` from Task 2 already handle a `%Schemas.Comment{}`.)

- [ ] **Run — expect pass.**

- [ ] **Full check + commit.** `mix precommit`. Commit: `feat(api): POST move / comments / needs-input card actions`.

**Deliverable:** the agent can move a card (board-scoped stage, 404 on foreign stage/ref), comment as "Relay AI" (201), and flag needs-input (sets `needs_input` + records the question) — completing the MMF 09 endpoint set, all thin over the contexts.

---

## Spec coverage

| Spec requirement / acceptance criterion | Task |
|---|---|
| Bearer auth → board; missing/invalid/revoked → 401 | 1 |
| `GET /api/board` returns stages + cards (status + owners), board-scoped | 1 |
| `GET /api/cards`, `GET /api/cards/:ref` (description + timeline) | 2 |
| `PATCH /api/cards/:ref` title/description/tag/status/owners | 2 |
| owners `["agent"]` claims → AI active; `["user:ID"]` hands back → human active | 2 |
| `POST /api/cards/:ref/move` (stage + optional position) | 3 |
| `POST /api/cards/:ref/comments` (as agent) | 3 |
| `POST /api/cards/:ref/needs-input` (status + question) | 3 |
| unknown/foreign `:ref` → 404 | 2, 3 |
| agent-attributed writes render as "Relay AI" in the timeline | 2, 3 |
| consistent JSON errors `{"error": {code, message}}` (400/401/404) | 1, 2, 3 |
| thin over `Cards`/`Boards`/`Activity`; no logic fork | all |
