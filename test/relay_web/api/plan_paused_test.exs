defmodule RelayWeb.Api.PlanPausedTest do
  # RE460, RE469 — a held owner's board, and a Free owner's read-only board (every counted board
  # but the editable one), is refused 402 `plan_paused` on every board-key request and on the
  # native `/api/all` writes; reads on `/api/all` still work, and paying lifts the refusal.
  use RelayWeb.ConnCase, async: true

  alias Relay.Accounts
  alias Relay.Billing
  alias Relay.Boards
  alias Relay.Cards

  @refusal %{
    "error" => %{
      "code" => "plan_paused",
      "message" => "This board is read-only: its owner's plan is paused or on Free. See /account/billing."
    }
  }

  setup do
    Process.put(:billing_enabled, true)
    %{today: Date.utc_today()}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp board_key(board) do
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    token
  end

  defp held!(owner, today), do: insert(:billing_account, user: owner, held_on: today, hold_reason: "test")

  defp active!(owner, today),
    do: insert(:billing_account, user: owner, paid_through: Date.add(today, 10), billing_day: today.day)

  describe "board-key /api" do
    test "a held owner's board answers 402 plan_paused (scenario 1)", %{conn: conn, today: today} do
      board = insert(:board)
      held!(board.owner, today)

      conn = conn |> auth(board_key(board)) |> get(~p"/api/board")

      assert json_response(conn, 402) == @refusal
    end

    test "card create, claim and heartbeat are all refused and no card exists (scenario 2)", %{
      conn: conn,
      today: today
    } do
      board = insert(:board)
      insert(:stage, board: board, name: "Backlog", type: :queue, position: 0)
      held!(board.owner, today)
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

    test "with billing disabled a held owner's board is served (scenario 4)", %{conn: conn, today: today} do
      Process.put(:billing_enabled, false)
      board = insert(:board)
      held!(board.owner, today)

      conn = conn |> auth(board_key(board)) |> get(~p"/api/board")

      assert json_response(conn, 200)["board"]["key"] == board.key
    end

    test "an invalid key is still 401 unauthorized (scenario 5)", %{conn: conn, today: today} do
      board = insert(:board)
      held!(board.owner, today)

      conn = conn |> auth("rl_not_a_real_key") |> get(~p"/api/board")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "a Free owner's read-only board answers 402; the editable one is served", %{conn: conn} do
      %{a: a, b: b} = free_owner_of_two()

      assert conn |> auth(board_key(a)) |> get(~p"/api/board") |> json_response(402) == @refusal
      served = build_conn() |> auth(board_key(b)) |> get(~p"/api/board") |> json_response(200)
      assert served["board"]["key"] == "BBB"
    end

    test "upgrading lifts the read-only refusal (scenario 7)", %{conn: conn, today: today} do
      %{owner: owner, a: a} = free_owner_of_two()
      token = board_key(a)

      assert conn |> auth(token) |> get(~p"/api/board") |> json_response(402) == @refusal

      assert {:ok, %{charged: :paid}} = Billing.complete_setup("local_4242_#{owner.id}", owner.id, today)

      assert build_conn() |> auth(token) |> get(~p"/api/board") |> json_response(200)
    end
  end

  # A Free owner with boards A (older) and B, a card on B the newest activity: B is editable, A
  # read-only. Each has a Backlog; A holds one old card.
  defp free_owner_of_two do
    owner = insert(:user)
    day_ago = DateTime.add(DateTime.utc_now(:second), -86_400)
    a = insert(:board, owner: owner, key: "AAA", slug: unique_slug("free-a"), updated_at: DateTime.add(day_ago, -60))
    b = insert(:board, owner: owner, key: "BBB", slug: unique_slug("free-b"), updated_at: DateTime.add(day_ago, -30))
    a_backlog = insert(:stage, board: a, name: "Backlog", type: :queue, position: 0)
    b_backlog = insert(:stage, board: b, name: "Backlog", type: :queue, position: 0)
    a_card = insert(:card, stage: a_backlog, updated_at: DateTime.add(day_ago, -60))
    insert(:card, stage: b_backlog)
    for board <- [a, b], do: insert(:membership, board: board, user: owner)
    insert(:billing_account, user: owner)
    %{owner: owner, a: a, b: b, a_card: a_card}
  end

  describe "/api/all as a Free owner" do
    setup do
      %{owner: owner} = free = free_owner_of_two()
      {:ok, %{token: token}} = Accounts.create_user_api_token(owner)
      Map.put(free, :user_conn, fn -> put_req_header(build_conn(), "authorization", "Bearer " <> token) end)
    end

    test "a write on the read-only board is refused; the editable board takes it", ctx do
      %{user_conn: user_conn, a: a, b: b} = ctx

      assert user_conn.()
             |> post(~p"/api/all/cards", %{board: a.slug, stage: "Backlog", title: "x"})
             |> json_response(402) == @refusal

      assert %{"data" => %{"title" => "y"}} =
               user_conn.()
               |> post(~p"/api/all/cards", %{board: b.slug, stage: "Backlog", title: "y"})
               |> json_response(201)

      assert length(Cards.list_cards(a)) == 1
    end

    test "a read on the read-only board answers 200", %{user_conn: user_conn, a: a, a_card: a_card} do
      assert user_conn.() |> get(~p"/api/all/cards/#{Cards.ref(a, a_card)}") |> json_response(200)
    end
  end

  describe "/api/all as a member of a held owner's board (scenario 6)" do
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

      held!(board.owner, today)

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
