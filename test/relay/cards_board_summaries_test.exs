defmodule Relay.CardsBoardSummariesTest do
  use Relay.DataCase, async: true

  alias Relay.Cards

  # RE376: the ONE definition of the per-board summary facts. BoardsLive (web /boards)
  # and GET /api/all/boards (the native switcher) both read these rows.

  defp member_board(user, key, slug) do
    board = insert(:board, key: key, slug: slug, name: "Board #{key}")
    insert(:membership, board: board, user: user)
    board
  end

  setup do
    %{user: insert(:user)}
  end

  test "one row per member board, with the summary facts", %{user: user} do
    alpha = member_board(user, "AAA", unique_slug("alpha"))
    code = insert_ai_stage(board: alpha, name: "Code", type: :work, position: 1)
    human = insert(:stage, board: alpha, name: "Polish", type: :work, position: 2)
    review = insert(:stage, board: alpha, name: "Review", type: :review, position: 3)
    # A substage never counts toward stage_count — only top-level stages do.
    insert(:stage, board: alpha, parent_id: code.id, name: "Code Review", type: :review, position: 4)

    insert(:card, stage: code, status: :needs_input)
    insert(:card, stage: review, status: :in_review)
    # Ready in a human, non-terminal work stage: awaiting-human — the web's third type,
    # which the two-type (mobile, ADR 0005) count must leave out.
    insert(:card, stage: human, status: :ready)
    # A stopped agent card: agent_stalled (RLY-148), counted by BOTH sums.
    stalled = insert(:card, stage: code, status: :working)
    insert(:card_owner, card: stalled)
    insert(:activity, card: stalled, type: :failure, text: "agent stopped")
    working = insert(:card, stage: code, status: :working)
    insert(:card_owner, card: working)
    # Archived cards are not counted.
    insert(:card, stage: code, archived_at: DateTime.truncate(DateTime.utc_now(), :second))

    assert [row] = Cards.list_board_summaries(user)

    assert row.board.id == alpha.id
    assert row.slug == alpha.slug
    assert row.name == "Board AAA"
    assert row.key == "AAA"
    assert row.stage_count == 3
    assert row.card_count == 5
    assert row.ai_active? == true
    # needs_input + in_review + agent_stalled
    assert row.needs_you_two_type == 3
    # ... + awaiting_human
    assert row.needs_you_count == 4
  end

  test "an idle board with no AI-owned working card is not ai_active?", %{user: user} do
    beta = member_board(user, "BBB", unique_slug("beta"))
    stage = insert(:stage, board: beta, name: "Code", type: :work, position: 1)
    insert(:card, stage: stage, status: :working)

    assert [%{ai_active?: false, needs_you_two_type: 0}] = Cards.list_board_summaries(user)
  end

  test "boards the user is not a member of are excluded, member boards keep display order",
       %{user: user} do
    alpha = member_board(user, "AAA", unique_slug("alpha"))
    beta = member_board(user, "BBB", unique_slug("beta"))
    member_board(insert(:user), "ZZZ", unique_slug("zeta"))

    assert Enum.map(Cards.list_board_summaries(user), & &1.slug) == [alpha.slug, beta.slug]
  end

  test "rows come starred-first A–Z and carry starred?", %{user: user} do
    zeta = insert(:board, name: "zeta", key: "ZZZ")

    for b <- [zeta, insert(:board, name: "Alpha"), insert(:board, name: "mango")],
        do: insert(:membership, board: b, user: user)

    {:ok, true} = Relay.Boards.set_starred(user, zeta.slug, true)

    assert Enum.map(Cards.list_board_summaries(user), &{&1.name, &1.starred?}) ==
             [{"zeta", true}, {"Alpha", false}, {"mango", false}]
  end

  test "rows carry the caller's muted? (RE406), in display order", %{user: user} do
    alpha = insert(:board, name: "Alpha", key: "AAA")
    zeta = insert(:board, name: "zeta", key: "ZZZ")
    for b <- [zeta, alpha], do: insert(:membership, board: b, user: user)

    {:ok, true} = Relay.Boards.set_muted(user, zeta.slug, true)

    assert Enum.map(Cards.list_board_summaries(user), &{&1.name, &1.muted?}) ==
             [{"Alpha", false}, {"zeta", true}]
  end
end
