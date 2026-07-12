defmodule RelayWeb.Api.CardActionsTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    spec = insert(:stage, board: board, name: "Spec", position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, position: 2)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, spec: spec, code: code}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "move sets the card's stage and logs a moved entry as the agent", %{
    conn: conn,
    board: board,
    spec: spec,
    code: code
  } do
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

  test "needs-input records the durable :needs_input activity and stamps blocked_since", %{
    conn: conn,
    board: board,
    spec: spec
  } do
    card = insert(:card, stage: spec)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{question: "Blue or green?"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.any?(
             body["timeline"],
             &(&1["kind"] == "activity" and &1["type"] == "needs_input" and
                 &1["meta"]["question"] == "Blue or green?")
           )

    reloaded = Cards.get_card_by_ref(board, ref(board, card))
    assert reloaded.status == :needs_input
    assert %DateTime{} = reloaded.blocked_since
  end

  test "needs-input with a structured questions array blocks the card and stores the payload",
       %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    questions = [
      %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
      %{"prompt" => "Any size limit?"}
    ]

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{questions: questions})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "needs_input"

    entry =
      Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "needs_input"))

    assert entry["meta"]["questions"] == [
             %{"prompt" => "Which timezone?", "options" => ["Billing", "Viewer"], "allow_text" => true},
             %{"prompt" => "Any size limit?", "options" => [], "allow_text" => true}
           ]

    assert Cards.get_card_by_ref(board, ref(board, card)).status == :needs_input
  end

  test "needs-input with an explicit null options value blocks the card instead of crashing",
       %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    questions = [%{"prompt" => "Nullable?", "options" => nil}]

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{questions: questions})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "needs_input"

    entry =
      Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "needs_input"))

    assert entry["meta"]["questions"] == [%{"prompt" => "Nullable?", "options" => [], "allow_text" => true}]
  end

  test "needs-input with an explicit null allow_text value blocks the card and defaults to true",
       %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    questions = [%{"prompt" => "Nullable?", "allow_text" => nil}]

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{questions: questions})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "needs_input"

    entry =
      Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "needs_input"))

    assert entry["meta"]["questions"] == [%{"prompt" => "Nullable?", "options" => [], "allow_text" => true}]
  end

  test "needs-input still accepts a plain string question", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{question: "Which region?"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "needs_input"
  end

  test "needs-input with a malformed questions payload is invalid and does not block the card",
       %{conn: conn, board: board, spec: spec} do
    for bad <- [
          %{questions: "nope"},
          %{questions: []},
          %{questions: [%{"options" => ["a"]}]},
          %{questions: [%{"prompt" => "  "}]},
          %{questions: [%{"prompt" => "no way to answer", "options" => [], "allow_text" => false}]}
        ] do
      card = insert(:card, stage: spec)

      assert conn
             |> post(~p"/api/cards/#{ref(board, card)}/needs-input", bad)
             |> json_response(400)

      assert Cards.get_card_by_ref(board, ref(board, card)).status != :needs_input
    end
  end

  test "the human's answer reaches the agent via the card timeline", %{
    conn: conn,
    board: board,
    code: code
  } do
    card = insert(:card, stage: code)
    {:ok, blocked} = Cards.request_input(card, "Which region?")
    {:ok, _answered} = Cards.answer_input(blocked, "us-east-1", {:user, board.owner_id})

    body =
      conn
      |> get(~p"/api/cards/#{ref(board, card)}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["status"] == "working"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["body"] == "us-east-1"))
    assert Enum.any?(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "input_answered"))
  end

  test "needs-input with a non-string question is invalid", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)

    assert conn
           |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{question: 42})
           |> json_response(400)
  end

  test "actions on an unknown ref 404", %{conn: conn} do
    assert conn |> post(~p"/api/cards/RLY-9999/comments", %{body: "x"}) |> json_response(404)
  end

  test "move with a non-numeric stage 404s instead of crashing", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/move", %{stage: "abc"}) |> json_response(404)
  end

  test "move with a non-numeric position returns 400 instead of crashing", %{
    conn: conn,
    board: board,
    spec: spec,
    code: code
  } do
    card = insert(:card, stage: spec)

    assert conn
           |> post(~p"/api/cards/#{ref(board, card)}/move", %{stage: code.id, position: "xyz"})
           |> json_response(400)
  end

  test "comments without a body returns 400 instead of crashing", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/comments", %{}) |> json_response(400)
  end

  test "needs-input without a question returns 400 instead of crashing", %{conn: conn, board: board, spec: spec} do
    card = insert(:card, stage: spec)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/needs-input", %{}) |> json_response(400)
  end
end
