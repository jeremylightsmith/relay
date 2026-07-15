defmodule RelayWeb.Api.AllActionsTest do
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

  defp member_board(user, key, slug) do
    board = insert(:board, key: key, slug: slug)
    insert(:membership, board: board, user: user)
    board
  end

  # A board whose Code stage has a Review sub-lane — the shape every review action needs.
  defp board_with_review(user, key \\ "AAA", slug \\ "alpha") do
    board = member_board(user, key, slug)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 1)
    insert(:stage, board: board, name: "Done", category: :complete, type: :done, position: 2)
    {:ok, review} = Boards.enable_lane(code, :review)
    {board, code, review}
  end

  defp timeline_types(card), do: Enum.map(Activity.list_timeline(card), &Map.get(&1, :type))

  test "approve advances the card and attributes the move to the human", %{conn: conn, user: user} do
    {board, _code, review} = board_with_review(user)
    card = insert(:card, stage: review, status: :in_review)

    body =
      conn
      |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/approve")
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["ref"] == Cards.ref(board, card)
    refute Cards.get_card_by_ref(board, Cards.ref(board, card)).stage_id == review.id

    approved = Enum.find(Activity.list_timeline(%Schemas.Card{id: card.id}), &(Map.get(&1, :type) == :approved))
    assert approved.actor_type == :user
    assert approved.user_id == user.id
  end

  test "approve off a review stage is 422 not_in_review", %{conn: conn, user: user} do
    {board, code, _review} = board_with_review(user)
    card = insert(:card, stage: code, status: :working)

    assert conn
           |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/approve")
           |> json_response(422)
           |> get_in(["error", "code"]) == "not_in_review"
  end

  test "reject records the note and sends the card back, as the human", %{conn: conn, user: user} do
    {board, code, review} = board_with_review(user)
    card = insert(:card, stage: review, status: :in_review)

    conn
    |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/reject", %{note: "needs tests"})
    |> json_response(200)

    reloaded = Cards.get_card_by_ref(board, Cards.ref(board, card))
    assert reloaded.stage_id == code.id
    assert reloaded.rejection.note == "needs tests"

    rejected = Enum.find(Activity.list_timeline(%Schemas.Card{id: card.id}), &(Map.get(&1, :type) == :rejected))
    assert rejected.actor_type == :user
  end

  test "reject without a note is 422 missing_note", %{conn: conn, user: user} do
    {board, _code, review} = board_with_review(user)
    card = insert(:card, stage: review, status: :in_review)

    assert conn
           |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/reject", %{})
           |> json_response(422)
           |> get_in(["error", "code"]) == "missing_note"

    assert conn
           |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/reject", %{note: "  "})
           |> json_response(422)
           |> get_in(["error", "code"]) == "missing_note"
  end

  test "answer with structured picks composes the numbered comment and resumes the card",
       %{conn: conn, user: user} do
    {board, code, _review} = board_with_review(user)
    card = insert(:card, stage: code, status: :working)

    {:ok, _} =
      Cards.request_input(
        card,
        [
          %{"prompt" => "Which region?", "options" => ["us", "eu"], "allow_text" => false},
          %{"prompt" => "Ship it?", "options" => [], "allow_text" => true}
        ],
        :agent
      )

    body =
      conn
      |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/answer", %{
        answers: [%{value: "eu"}, %{value: "yes"}]
      })
      |> json_response(200)
      |> Map.fetch!("data")

    # code is an AI work stage, so the answered card hands the baton back to the agent.
    assert body["status"] == "working"
    assert Cards.get_card_by_ref(board, Cards.ref(board, card)).status == :working

    answer =
      %Schemas.Card{id: card.id}
      |> Activity.list_timeline()
      |> Enum.filter(&match?(%Schemas.Comment{}, &1))
      |> List.last()

    assert answer.body == "1. Which region? → eu\n2. Ship it? → yes"
    assert answer.actor_type == :user
    assert :input_answered in timeline_types(%Schemas.Card{id: card.id})
  end

  test "answer accepts the flat free-text fallback", %{conn: conn, user: user} do
    {board, code, _review} = board_with_review(user)
    card = insert(:card, stage: code, status: :working)
    {:ok, _} = Cards.request_input(card, "Which region?", :agent)

    conn
    |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/answer", %{answer: "eu, please"})
    |> json_response(200)

    answer =
      %Schemas.Card{id: card.id}
      |> Activity.list_timeline()
      |> Enum.filter(&match?(%Schemas.Comment{}, &1))
      |> List.last()

    assert answer.body == "eu, please"
    assert Cards.get_card_by_ref(board, Cards.ref(board, card)).status == :working
  end

  test "answering a card that isn't waiting on you is 422 not_needs_input", %{conn: conn, user: user} do
    {board, code, _review} = board_with_review(user)
    card = insert(:card, stage: code, status: :working)

    assert conn
           |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/answer", %{answer: "hi"})
           |> json_response(422)
           |> get_in(["error", "code"]) == "not_needs_input"
  end

  test "an empty answer body is 400", %{conn: conn, user: user} do
    {board, code, _review} = board_with_review(user)
    card = insert(:card, stage: code, status: :working)
    {:ok, _} = Cards.request_input(card, "Which region?", :agent)

    assert conn
           |> post(~p"/api/all/cards/#{Cards.ref(board, card)}/answer", %{answer: "   "})
           |> json_response(400)
  end

  test "acting on a board the user is not a member of is 404, not 403", %{conn: conn} do
    other = insert(:board, key: "ZZZ", slug: "zeta")
    code = insert(:stage, board: other, name: "Code", type: :work, ai_enabled: true, position: 1)
    {:ok, review} = Boards.enable_lane(code, :review)
    card = insert(:card, stage: review, status: :in_review)

    assert conn
           |> post(~p"/api/all/cards/#{Cards.ref(other, card)}/approve")
           |> json_response(404)
           |> get_in(["error", "code"]) == "not_found"
  end

  test "an unknown ref is 404", %{conn: conn, user: user} do
    {_board, _code, _review} = board_with_review(user)

    assert conn |> post(~p"/api/all/cards/AAA-9999/approve") |> json_response(404)
    assert conn |> post(~p"/api/all/cards/nonsense/approve") |> json_response(404)
  end

  test "a ref matching two of the user's boards is 422 until board disambiguates it",
       %{conn: conn, user: user} do
    # Board keys are not unique — every board defaults to "RLY" and create_board derives the
    # key from the name without a collision check, so this is the common case, not a corner.
    {alpha, _code_a, review_a} = board_with_review(user, "RLY", "alpha")
    {beta, _code_b, review_b} = board_with_review(user, "RLY", "beta")

    a = insert(:card, stage: review_a, status: :in_review, ref_number: 7)
    b = insert(:card, stage: review_b, status: :in_review, ref_number: 7)

    assert Cards.ref(alpha, a) == Cards.ref(beta, b)

    assert conn
           |> post(~p"/api/all/cards/RLY-7/approve")
           |> json_response(422)
           |> get_in(["error", "code"]) == "ambiguous_ref"

    # The feed hands every row its board slug, so a real client always has the tiebreak.
    conn |> post(~p"/api/all/cards/RLY-7/approve", %{board: "beta"}) |> json_response(200)

    assert Cards.get_card_by_ref(beta, "RLY-7").stage_id != review_b.id
    assert Cards.get_card_by_ref(alpha, "RLY-7").stage_id == review_a.id
  end
end
