defmodule Relay.Activity.PrunerTest do
  use Relay.DataCase, async: false

  import Ecto.Query

  alias Relay.Activity.Pruner

  test "prunes only :action chatter older than the retention window — the card's story survives" do
    card = insert(:card)
    old = DateTime.utc_now() |> DateTime.add(-20 * 24 * 3600, :second) |> DateTime.truncate(:second)
    recent = DateTime.utc_now() |> DateTime.add(-2 * 24 * 3600, :second) |> DateTime.truncate(:second)

    stale_action = insert(:activity, card: card, type: :action, text: "old chatter", inserted_at: old)
    old_move = insert(:activity, card: card, type: :moved, inserted_at: old)
    old_failure = insert(:activity, card: card, type: :failure, text: "died", inserted_at: old)
    old_decision = insert(:activity, card: card, type: :approved, inserted_at: old)
    fresh_action = insert(:activity, card: card, type: :action, text: "new chatter", inserted_at: recent)

    pruner = start_supervised!({Pruner, name: :pruner_test, interval: to_timeout(hour: 6)})
    send(pruner, :prune)
    :sys.get_state(pruner)

    ids = Repo.all(from a in Schemas.Activity, select: a.id)

    refute stale_action.id in ids
    assert old_move.id in ids
    assert old_failure.id in ids
    assert old_decision.id in ids
    assert fresh_action.id in ids
  end
end
