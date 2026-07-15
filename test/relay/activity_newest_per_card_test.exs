defmodule Relay.ActivityNewestPerCardTest do
  use Relay.DataCase, async: true

  alias Relay.Activity

  describe "newest_per_card/1" do
    test "returns the newest entry per card, not the newest overall" do
      old = DateTime.from_naive!(~N[2026-07-01 10:00:00], "Etc/UTC")
      new = DateTime.from_naive!(~N[2026-07-01 11:00:00], "Etc/UTC")

      card_a = insert(:card)
      card_b = insert(:card)

      insert(:activity, card: card_a, type: :action, text: "a old", inserted_at: old)
      insert(:activity, card: card_a, type: :action, text: "a new", inserted_at: new)
      insert(:activity, card: card_b, type: :action, text: "b only", inserted_at: old)

      newest = Activity.newest_per_card([card_a.id, card_b.id])

      assert newest[card_a.id].text == "a new"
      assert newest[card_b.id].text == "b only"
    end

    test "same-second ties break by ascending id, so the last insert wins" do
      at = DateTime.from_naive!(~N[2026-07-01 10:00:00], "Etc/UTC")
      card = insert(:card)

      insert(:activity, card: card, type: :action, text: "first", inserted_at: at)
      insert(:activity, card: card, type: :action, text: "second", inserted_at: at)

      assert Activity.newest_per_card([card.id])[card.id].text == "second"
    end

    test "a card with no entries is absent from the map" do
      card = insert(:card)
      assert Activity.newest_per_card([card.id]) == %{}
    end

    test "an empty id list returns an empty map" do
      assert Activity.newest_per_card([]) == %{}
    end
  end
end
