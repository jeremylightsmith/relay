defmodule RelayWeb.Api.PlanPausedTest do
  # RE460 — a paused owner's board is refused 402 `plan_paused` on every board-key request and on
  # the native `/api/all` writes; reads on `/api/all` still work, and paying lifts the refusal.
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts
  alias Relay.Billing
  alias Relay.Boards
  alias Relay.Cards

  @refusal %{"error" => %{"code" => "plan_paused", "message" => "This board's plan is paused."}}

  setup do
    Process.put(:billing_enabled, true)
    %{today: Date.utc_today()}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp board_key(board) do
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    token
  end

  defp paused!(owner, today),
    do: insert(:billing_account, user: owner, paid_through: Date.add(today, -10), billing_day: today.day)

  defp active!(owner, today),
    do: insert(:billing_account, user: owner, paid_through: Date.add(today, 10), billing_day: today.day)

  describe "board-key /api" do
    test "a paused owner's board answers 402 plan_paused (scenario 1)", %{conn: conn, today: today} do
      board = insert(:board)
      paused!(board.owner, today)

      conn = conn |> auth(board_key(board)) |> get(~p"/api/board")

      assert json_response(conn, 402) == @refusal
    end

    test "card create, claim and heartbeat are all refused and no card exists (scenario 2)", %{
      conn: conn,
      today: today
    } do
      board = insert(:board)
      insert(:stage, board: board, name: "Backlog", type: :queue, position: 0)
      paused!(board.owner, today)
      token = board_key(board)

      assert conn |> auth(token) |> post(~p"/api/cards", %{"title" => "x"}) |> json_response(402) == @refusal

      assert build_conn() |> auth(token) |> post("/api/node-jobs/claim?wait=0") |> json_response(402) ==
               @refusal

      assert build_conn() |> auth(token) |> post(~p"/api/node-jobs/heartbeat") |> json_response(402) == @refusal

      assert Cards.list_cards(board) == []
    end

    test "an active owner's board is served (scenario 3)", %{conn: conn, today: today} do
      board = insert(:board)
      active!(board.owner, today)

      conn = conn |> auth(board_key(board)) |> get(~p"/api/board")

      assert json_response(conn, 200)["board"]["key"] == board.key
    end

    test "with billing disabled a paused owner's board is served (scenario 4)", %{conn: conn, today: today} do
      Process.put(:billing_enabled, false)
      board = insert(:board)
      paused!(board.owner, today)

      conn = conn |> auth(board_key(board)) |> get(~p"/api/board")

      assert json_response(conn, 200)["board"]["key"] == board.key
    end

    test "an invalid key is still 401 unauthorized (scenario 5)", %{conn: conn, today: today} do
      board = insert(:board)
      paused!(board.owner, today)

      conn = conn |> auth("rl_not_a_real_key") |> get(~p"/api/board")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "paying lifts the refusal (scenario 7)", %{conn: conn, today: today} do
      board = insert(:board)
      paused!(board.owner, today)
      token = board_key(board)

      assert conn |> auth(token) |> get(~p"/api/board") |> json_response(402) == @refusal

      assert {:ok, %{charged: :paid}} =
               Billing.complete_setup("local_4242_#{board.owner_id}", board.owner_id, today)

      assert build_conn() |> auth(token) |> get(~p"/api/board") |> json_response(200)
    end
  end

  describe "/api/all as a member of a paused board (scenario 6)" do
    setup %{today: today} do
      member = insert(:user)
      {:ok, %{token: token}} = Accounts.create_user_api_token(member)

      board = insert(:board, key: "PAU", slug: unique_slug("paused"))
      insert(:membership, board: board, user: member)
      backlog = insert(:stage, board: board, name: "Backlog", type: :queue, position: 0)
      code = insert(:stage, board: board, name: "Code", type: :work, position: 1)
      insert(:stage, board: board, name: "Done", category: :complete, type: :done, position: 2)
      {:ok, review} = Boards.enable_lane(code, :review)

      in_review = insert(:card, stage: review, status: :in_review)
      asking = insert(:card, stage: code, status: :working)
      {:ok, _} = Cards.request_input(asking, "Which region?", :agent)

      paused!(board.owner, today)

      %{
        user_conn: fn -> put_req_header(build_conn(), "authorization", "Bearer " <> token) end,
        board: board,
        backlog: backlog,
        in_review: in_review,
        asking: asking
      }
    end

    test "create, approve, reject and answer are refused and change nothing", ctx do
      %{user_conn: user_conn, board: board, in_review: in_review, asking: asking} = ctx
      before = board |> Cards.list_cards() |> Enum.map(&{&1.id, &1.stage_id, &1.status}) |> Enum.sort()

      assert user_conn.()
             |> post(~p"/api/all/cards", %{board: board.slug, stage: "Backlog", title: "x"})
             |> json_response(402) == @refusal

      assert user_conn.()
             |> post(~p"/api/all/cards/#{Cards.ref(board, in_review)}/approve")
             |> json_response(402) == @refusal

      assert user_conn.()
             |> post(~p"/api/all/cards/#{Cards.ref(board, in_review)}/reject", %{note: "not yet"})
             |> json_response(402) == @refusal

      assert user_conn.()
             |> post(~p"/api/all/cards/#{Cards.ref(board, asking)}/answer", %{answer: "eu, please"})
             |> json_response(402) == @refusal

      assert board |> Cards.list_cards() |> Enum.map(&{&1.id, &1.stage_id, &1.status}) |> Enum.sort() == before
    end

    test "show, feed and boards still answer 200", ctx do
      %{user_conn: user_conn, board: board, in_review: in_review} = ctx

      assert user_conn.() |> get(~p"/api/all/cards/#{Cards.ref(board, in_review)}") |> json_response(200)
      assert user_conn.() |> get(~p"/api/all/feed") |> json_response(200)
      assert user_conn.() |> get(~p"/api/all/boards") |> json_response(200)
    end
  end
end
