defmodule Relay.CardsClearFailureTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Cards

  setup do
    board = insert(:board)
    stage = insert(:stage, board: board, type: :work, ai_enabled: true)
    card = insert(:card, board: board, stage: stage, status: :failed)
    insert(:card_owner, card: card)
    %{board: board, card: card}
  end

  test "a failed card goes back to :working", %{card: card} do
    {:ok, card} = Cards.clear_failure(card, :agent)
    assert card.status == :working
  end

  test "it logs an :action entry naming the retry", %{card: card} do
    {:ok, card} = Cards.clear_failure(card, :agent)

    [newest | _rest] = Activity.list_activity(card)
    assert newest.type == :action
    assert newest.text == "failure cleared by retry"
    assert newest.actor_type == :agent
  end

  test "it is attributable to a user", %{card: card} do
    user = insert(:user)
    {:ok, card} = Cards.clear_failure(card, {:user, user.id})

    [newest | _rest] = Activity.list_activity(card)
    assert newest.actor_type == :user
    assert newest.user_id == user.id
  end
end
