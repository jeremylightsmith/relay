defmodule Relay.CardsPublicDescriptionTest do
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Relay.Events

  test "set_public_description sets, clears, and broadcasts without touching description" do
    card = insert(:card, description: "internal only")
    Events.subscribe(card.board_id)

    assert {:ok, updated} = Cards.set_public_description(card, "  Ship the mobile app  ")
    assert updated.public_description == "  Ship the mobile app  "
    assert updated.description == "internal only"
    assert_receive {:card_upserted, _}

    assert {:ok, cleared} = Cards.set_public_description(updated, "   ")
    assert cleared.public_description == nil
  end
end
