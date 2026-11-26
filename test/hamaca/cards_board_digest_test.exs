defmodule Hamaca.CardsBoardDigestTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Cards
  alias Schemas.CardOwner

  # RE519: the baton-first digest `board_status` renders — waiting on you, agents working,
  # shipped this week — and the one "an agent is working this card" predicate.

  defp member_board(user, name, key) do
    board = insert(:board, name: name, key: key, slug: unique_slug(String.downcase(key)))
    insert(:membership, board: board, user: user)
    board
  end

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)

  defp ids(cards), do: Enum.map(cards, & &1.id)

  setup do
    %{user: insert(:user), now: DateTime.truncate(DateTime.utc_now(), :second)}
  end

  # Scenario 5
  test "waiting oldest first, agent-working cards with their stage, and this week's shipped cards",
       %{user: user, now: now} do
    board = member_board(user, "Relay", "RDA")
    code = insert_ai_stage(board: board, name: "Code", position: 1)
    review = insert(:stage, board: board, name: "Review", type: :review, position: 2)
    done = insert(:stage, board: board, name: "Done", category: :complete, position: 3)

    a = insert(:card, stage: code, status: :needs_input, blocked_since: ago(now, 3 * 3600))
    b = insert(:card, stage: review, status: :in_review, updated_at: ago(now, 3600))

    c = insert(:card, stage: code, status: :working)
    insert(:card_owner, card: c)
    insert(:sub_task, card: c, done: true)
    insert(:sub_task, card: c, done: true)
    insert(:sub_task, card: c, done: false)

    d = insert(:card, stage: code, status: :working)
    insert(:card_owner, card: d, user: user)

    e = insert(:card, stage: done, status: :ready, done_at: ago(now, 2 * 86_400))
    _f = insert(:card, stage: done, status: :ready, done_at: ago(now, 10 * 86_400))

    other = member_board(user, "Other", "ODA")
    other_stage = insert(:stage, board: other, name: "Code", position: 1)
    _g = insert(:card, stage: other_stage, status: :needs_input, blocked_since: ago(now, 5 * 3600))

    digest = Cards.board_digest(user, board, now)

    assert digest.waiting |> Enum.map(& &1.card) |> ids() == [a.id, b.id]
    assert [%{card: working_card, stage: %{name: "Code"}}] = digest.working
    assert working_card.id == c.id
    refute d.id in (digest.working |> Enum.map(& &1.card) |> ids())
    assert ids(digest.shipped) == [e.id]
  end

  # Scenario 6
  test "a board with no stages has an empty digest", %{user: user, now: now} do
    board = member_board(user, "Empty", "EDA")

    assert Cards.board_digest(user, board, now) == %{waiting: [], working: [], shipped: []}
  end

  test "the shipped window is 7 days" do
    assert Cards.shipped_window_days() == 7
  end

  # Scenario 7
  describe "agent_working?/1" do
    test "a working card the agent owns" do
      assert Cards.agent_working?(%{status: :working, owners: [%CardOwner{actor_type: :agent}]})
    end

    test "a working card only a human owns" do
      refute Cards.agent_working?(%{status: :working, owners: [%CardOwner{actor_type: :user, user_id: 1}]})
    end

    test "a ready card the agent owns" do
      refute Cards.agent_working?(%{status: :ready, owners: [%CardOwner{actor_type: :agent}]})
    end
  end

  test "waiting_since/1 is blocked_since, else updated_at", %{now: now} do
    blocked = ago(now, 3600)
    assert Cards.waiting_since(%{blocked_since: blocked, updated_at: now}) == blocked
    assert Cards.waiting_since(%{blocked_since: nil, updated_at: now}) == now
  end
end
