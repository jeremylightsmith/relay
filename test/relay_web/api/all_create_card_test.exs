defmodule RelayWeb.Api.AllCreateCardTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts
  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, %{token: token}} = Accounts.create_user_api_token(user)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), user: user}
  end

  # A member board with a queue stage, an AI work stage with a Review sub-lane, and Done —
  # the shapes create must accept (top-level) and refuse (substage).
  defp board_with_stages(user, key \\ "AAA", slug \\ "alpha") do
    board = insert(:board, key: key, slug: slug)
    insert(:membership, board: board, user: user)
    backlog = insert(:stage, board: board, name: "Backlog", type: :queue, position: 0)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    insert(:stage, board: board, name: "Done", category: :complete, type: :done, position: 2)
    {:ok, review} = Boards.enable_lane(code, :review)
    {board, backlog, review}
  end

  test "201 creates at the top of the named stage, attributed to the human", %{conn: conn, user: user} do
    {board, backlog, _review} = board_with_stages(user)
    {:ok, _existing} = Cards.create_card(backlog, %{title: "already here"})

    body =
      conn
      |> post(~p"/api/all/cards", %{
        board: board.slug,
        stage: "Backlog",
        title: "api test",
        description: "the details"
      })
      |> json_response(201)
      |> Map.fetch!("data")

    assert body["title"] == "api test"
    assert body["description"] == "the details"
    assert body["stage_id"] == backlog.id

    card = Cards.get_card_by_ref(board, body["ref"])
    [first | _] = board |> Cards.list_cards() |> Enum.filter(&(&1.stage_id == backlog.id))
    assert first.id == card.id

    created =
      Enum.find(Activity.list_timeline(%Schemas.Card{id: card.id}), &(Map.get(&1, :type) == :created))

    assert created.actor_type == :user
    assert created.user_id == user.id
  end

  test "404 for an unknown board slug", %{conn: conn, user: user} do
    {_board, _backlog, _review} = board_with_stages(user)

    assert conn
           |> post(~p"/api/all/cards", %{board: "nope", stage: "Backlog", title: "x"})
           |> json_response(404)
           |> get_in(["error", "code"]) == "not_found"
  end

  test "404 for a board the user is not a member of (no existence leak)", %{conn: conn, user: user} do
    {_board, _backlog, _review} = board_with_stages(user)
    foreign = insert(:board, key: "BBB", slug: "beta")
    insert(:stage, board: foreign, name: "Backlog", type: :queue, position: 0)

    assert conn
           |> post(~p"/api/all/cards", %{board: "beta", stage: "Backlog", title: "x"})
           |> json_response(404)
           |> get_in(["error", "code"]) == "not_found"
  end

  test "404 when the board param is missing", %{conn: conn, user: user} do
    {_board, _backlog, _review} = board_with_stages(user)

    assert conn
           |> post(~p"/api/all/cards", %{stage: "Backlog", title: "x"})
           |> json_response(404)
           |> get_in(["error", "code"]) == "not_found"
  end

  test "422 missing_title for a blank or absent title", %{conn: conn, user: user} do
    {board, _backlog, _review} = board_with_stages(user)

    assert conn
           |> post(~p"/api/all/cards", %{board: board.slug, stage: "Backlog", title: "   "})
           |> json_response(422)
           |> get_in(["error", "code"]) == "missing_title"

    assert conn
           |> post(~p"/api/all/cards", %{board: board.slug, stage: "Backlog"})
           |> json_response(422)
           |> get_in(["error", "code"]) == "missing_title"
  end

  test "422 invalid_stage for an unknown stage name", %{conn: conn, user: user} do
    {board, _backlog, _review} = board_with_stages(user)

    assert conn
           |> post(~p"/api/all/cards", %{board: board.slug, stage: "Nope", title: "x"})
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_stage"
  end

  test "422 invalid_stage for a substage name — gates are not intake points", %{conn: conn, user: user} do
    {board, _backlog, review} = board_with_stages(user)

    assert conn
           |> post(~p"/api/all/cards", %{board: board.slug, stage: review.name, title: "x"})
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_stage"
  end

  test "401 without a bearer token" do
    conn = post(build_conn(), ~p"/api/all/cards", %{board: "alpha", stage: "Backlog", title: "x"})
    assert conn.status == 401
  end
end
