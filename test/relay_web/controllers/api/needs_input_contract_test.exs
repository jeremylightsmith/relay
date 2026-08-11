defmodule RelayWeb.Api.NeedsInputContractTest do
  @moduledoc """
  The questions schema `bin/relay` teaches every agent must be one the server actually accepts.

  `OUTCOME_CONTRACT` is appended to every agent node's prompt, and it now carries a worked
  `--questions` payload — the one thing an agent needs in order to ask a human and the one thing
  that used to be missing. That example is prose in a Python file; `valid_questions?` is Elixir.
  Nothing but this test stops the two from drifting, and the failure mode is silent: an agent
  follows the documented shape, the server 422s it, the node exits without parking and without an
  outcome, and `determine_agent_outcome` reports `failed` with the question never delivered.

  So this reads the literal example out of `bin/relay` and POSTs it at the real route. No payload
  is retyped here — retyping it would pin this test to itself rather than to what ships.
  """
  use RelayWeb.ConnCase, async: true

  alias Relay.ApiKeys
  alias Schemas.Card

  # The one parse of the example out of bin/relay: the heredoc body inside OUTCOME_CONTRACT's
  # needs-input block, between `<<'JSON'` and its terminator. Matched structurally, against the
  # contract text agents actually receive, so editorial edits to the surrounding prose never
  # break it and no copy can be validated that is not the shipped one.
  @example_re ~r/<<'JSON'\n(?<json>.*?)\nJSON\n/s

  setup %{conn: conn} do
    user = insert(:user)
    board = insert(:board, key: "NI", slug: "needs-input-contract")
    insert(:membership, board: board, user: user)
    stage = insert(:stage, board: board)
    card = insert(:card, stage: stage, ref_number: 1, title: "A card to ask about")
    {:ok, %{token: token}} = ApiKeys.create_key(board, user)

    {:ok, conn: put_req_header(conn, "authorization", "Bearer " <> token), card: card}
  end

  defp documented_example do
    %{"json" => json} = Regex.named_captures(@example_re, File.read!("bin/relay"))
    Jason.decode!(json)
  end

  test "the example bin/relay teaches is accepted by the real endpoint", %{conn: conn, card: card} do
    questions = documented_example()

    conn = post(conn, ~p"/api/cards/NI-1/needs-input", %{"questions" => questions})

    assert %{"data" => data} = json_response(conn, 200)
    assert data["status"] == "needs_input"
    assert Relay.Repo.get!(Card, card.id).status == :needs_input
  end

  test "the example teaches both branches of the answerable? rule" do
    questions = documented_example()

    # options + free text, and a genuinely open ask. An example covering one branch teaches
    # half the schema, and the half it omits is the one that gets refused.
    assert Enum.any?(questions, &(&1["options"] not in [nil, []]))
    assert Enum.any?(questions, &(&1["options"] == [] and &1["allow_text"] == true))

    for q <- questions, do: assert(String.trim(q["prompt"]) != "")
  end

  test "a payload missing the shape the example teaches is refused", %{conn: conn} do
    # Guards the test above: proves the route discriminates, so "accepted" means something.
    # `allow_text: false` with no options is unanswerable — the rule an agent is most likely
    # to break by trimming the example down.
    conn =
      post(conn, ~p"/api/cards/NI-1/needs-input", %{
        "questions" => [%{"prompt" => "No way to answer this.", "options" => [], "allow_text" => false}]
      })

    assert json_response(conn, 400)
  end
end
