defmodule RelayWeb.Api.AllFeedTest do
  use RelayWeb.ConnCase, async: true

  import Ecto.Query

  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, %{token: token}} = Accounts.create_user_api_token(user)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), user: user}
  end

  # Board keys are not unique, so tests give each board a distinct key.
  defp member_board(user, key, slug) do
    board = insert(:board, key: key, slug: slug)
    insert(:membership, board: board, user: user)
    board
  end

  defp touch(card, at) do
    Relay.Repo.update_all(from(c in Schemas.Card, where: c.id == ^card.id), set: [updated_at: at])
    card
  end

  defp feed(conn), do: conn |> get(~p"/api/all/feed") |> json_response(200)

  test "aggregates both types across every board the user belongs to, newest block first",
       %{conn: conn, user: user} do
    alpha = member_board(user, "AAA", "alpha")
    beta = member_board(user, "BBB", "beta")

    work = insert(:stage, board: alpha, name: "Code", type: :work, ai_enabled: true, position: 1)
    review = insert(:stage, board: beta, name: "Review", type: :review, position: 1)

    older = insert(:card, stage: work, status: :needs_input, blocked_since: ~U[2026-07-10 09:00:00Z])
    newest = insert(:card, stage: work, status: :needs_input, blocked_since: ~U[2026-07-13 09:00:00Z])
    middle = touch(insert(:card, stage: review, status: :in_review), ~U[2026-07-11 09:00:00Z])

    body = feed(conn)

    assert body["meta"]["count"] == 3

    assert Enum.map(body["data"], & &1["ref"]) == [
             Cards.ref(alpha, newest),
             Cards.ref(beta, middle),
             Cards.ref(alpha, older)
           ]
  end

  test "excludes every status outside the two-type set, diverging from the board rollup",
       %{conn: conn, user: user} do
    board = member_board(user, "AAA", "alpha")
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    qa = insert(:stage, board: board, name: "QA", type: :work, ai_enabled: false, position: 2)

    insert(:card, stage: code, status: :working)
    insert(:card, stage: qa, status: :ready)

    assert feed(conn)["meta"]["count"] == 0

    # The board's rollup DOES count the ready-awaiting-human card. The mobile feed must not:
    # that divergence is the ADR 0005 two-type contract, not a bug.
    assert Cards.needs_you_rollup(board).awaiting_human == 1
  end

  test "a board the user is not a member of is absent", %{conn: conn} do
    other = insert(:board, key: "ZZZ", slug: "zeta")
    review = insert(:stage, board: other, name: "Review", type: :review, position: 1)
    insert(:card, stage: review, status: :in_review)

    assert feed(conn)["meta"]["count"] == 0
  end

  test "an archived card is absent", %{conn: conn, user: user} do
    board = member_board(user, "AAA", "alpha")
    review = insert(:stage, board: board, name: "Review", type: :review, position: 1)
    insert(:card, stage: review, status: :in_review, archived_at: ~U[2026-07-13 09:00:00Z])

    assert feed(conn)["meta"]["count"] == 0
  end

  test "a needs-input row renders with no second fetch", %{conn: conn, user: user} do
    board = member_board(user, "AAA", "alpha")
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    card = insert(:card, stage: code, status: :working, tag: "mobile")

    {:ok, _} =
      Cards.request_input(
        card,
        [%{"prompt" => "Which region?", "options" => ["us", "eu"], "allow_text" => false}],
        :agent
      )

    [row] = feed(conn)["data"]

    assert row["ref"] == Cards.ref(board, card)
    assert row["title"] == card.title
    assert row["board"] == %{"name" => board.name, "key" => "AAA", "slug" => "alpha"}
    # INPUT-01's breadcrumb is "<Board> / <Stage>", and D7 forbids a second fetch —
    # so the stage rides on the row like the board does.
    assert row["stage"] == "Code"
    assert row["tag"] == "mobile"
    assert row["status"] == "needs_input"
    assert row["kind"] == "needs_input"
    assert row["reason"] =~ "Which region?"
    assert row["blocked_at"]

    assert row["questions"] == [
             %{"prompt" => "Which region?", "options" => ["us", "eu"], "allow_text" => false}
           ]
  end

  test "a legacy string-only question carries reason but no structured questions",
       %{conn: conn, user: user} do
    board = member_board(user, "AAA", "alpha")
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    card = insert(:card, stage: code, status: :working)
    {:ok, _} = Cards.request_input(card, "Which region?", :agent)

    [row] = feed(conn)["data"]

    assert row["reason"] == "Which region?"
    refute row["questions"]
  end

  test "an in-review row's reason is the PR url when set, else the review stage name",
       %{conn: conn, user: user} do
    board = member_board(user, "AAA", "alpha")
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    {:ok, review} = Boards.enable_lane(code, :review)

    with_pr = insert(:card, stage: review, status: :in_review, pr_url: "https://example.com/pr/1")
    without_pr = insert(:card, stage: review, status: :in_review)

    reasons = Map.new(feed(conn)["data"], &{&1["ref"], &1["reason"]})

    assert reasons[Cards.ref(board, with_pr)] == "https://example.com/pr/1"
    assert reasons[Cards.ref(board, without_pr)] == "Code · Review"
    assert Enum.all?(feed(conn)["data"], &(&1["kind"] == "in_review"))
  end

  test "every row carries its stage display name, sublane included", %{conn: conn, user: user} do
    board = member_board(user, "AAA", "alpha")
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    {:ok, review} = Boards.enable_lane(code, :review)

    blocked = insert(:card, stage: code, status: :needs_input)
    {:ok, _} = Cards.request_input(blocked, "Which region?", :agent)
    reviewing = insert(:card, stage: review, status: :in_review)

    stages = Map.new(feed(conn)["data"], &{&1["ref"], &1["stage"]})

    assert stages[Cards.ref(board, blocked)] == "Code"
    assert stages[Cards.ref(board, reviewing)] == "Code · Review"
  end
end
