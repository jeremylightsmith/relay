defmodule Relay.CardsRetryTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Events

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board, type: :work, ai_enabled: true)
    card = insert(:card, board: board, stage: stage, status: :needs_input)
    insert(:card_owner, card: card)
    user = insert(:user)
    %{board: board, card: card, user: user}
  end

  test "appends a 'retry requested' :action entry attributed to the user, run_id nil", %{card: card, user: user} do
    {:ok, _card} = Cards.retry(card, {:user, user.id})

    [newest | _rest] = Activity.list_activity(card)
    assert newest.type == :action
    assert newest.text == "retry requested"
    assert newest.actor_type == :user
    assert newest.user_id == user.id
    assert newest.run_id == nil
  end

  test "sets a blocked card back to :working so the poller re-picks it", %{card: card, user: user} do
    {:ok, card} = Cards.retry(card, {:user, user.id})

    assert card.status == :working
  end

  test "a card already :working stays :working and logs no extra status change", %{card: card, user: user} do
    {:ok, card} = Cards.set_status(card, %{status: :working})
    {:ok, card} = Cards.retry(card, {:user, user.id})

    assert card.status == :working
    types = card |> Activity.list_activity() |> Enum.map(& &1.type)
    assert Enum.count(types, &(&1 == :status_changed)) == 1
  end

  test "broadcasts {:card_log_appended, card_id, [entry]} exactly like a runner append", %{
    board: board,
    card: card,
    user: user
  } do
    Events.subscribe(board.id)

    {:ok, _card} = Cards.retry(card, {:user, user.id})

    assert_receive {:card_log_appended, card_id, [entry]}
    assert card_id == card.id
    assert entry.text == "retry requested"
  end
end
