defmodule RelayWeb.StoryMapFilterTest do
  @moduledoc """
  RE259 — the owner-key wire format and the filter predicate, unit-tested against plain
  structs. No DB, no LiveView: this module owns the key format the way
  `RelayWeb.StoryMapGrid` owns the column keys, so it is proven the same way.
  """
  use ExUnit.Case, async: true

  alias RelayWeb.StoryMapFilter
  alias Schemas.Card
  alias Schemas.CardOwner
  alias Schemas.User

  defp user(id, name, email), do: %User{id: id, name: name, email: email, avatar_url: nil}

  defp human_owner(user), do: %CardOwner{actor_type: :user, user_id: user.id, user: user}
  defp ai_owner, do: %CardOwner{actor_type: :agent, user_id: nil, user: nil}

  defp card(id, owners, status \\ :ready) do
    %Card{id: id, board_id: 1, ref_number: id, title: "Card #{id}", status: status, owners: owners}
  end

  defp dana, do: user(3, "Dana Kim", "dana@acme.co")
  defp mara, do: user(4, "Mara Lopez", "mara@acme.co")

  describe "the owner-key wire format" do
    test "an owner row round-trips through its key" do
      assert StoryMapFilter.owner_key(human_owner(dana())) == "u:3"
      assert StoryMapFilter.owner_key(ai_owner()) == "agent"

      assert StoryMapFilter.parse_owner_key("u:3") == {:ok, {:user, 3}}
      assert StoryMapFilter.parse_owner_key("agent") == {:ok, :agent}

      # And a parsed key renders back to the CANONICAL string, which is what makes
      # `parse |> owner_key` a normalizer at the write boundary.
      assert StoryMapFilter.owner_key({:user, 3}) == "u:3"
      assert StoryMapFilter.owner_key(:agent) == "agent"
      assert StoryMapFilter.owner_key({:user, 7}) == "u:7"
    end

    test "a forged key is :error and creates no atom" do
      before = :erlang.system_info(:atom_count)

      for forged <- ["u:", "u:0", "u:-1", "u:abc", "u:3x", "", "agentx", "shoe_size"] do
        assert StoryMapFilter.parse_owner_key(forged) == :error
      end

      assert :erlang.system_info(:atom_count) == before
    end

    test "chip_dom_id/1 replaces the colon a CSS selector cannot carry" do
      assert StoryMapFilter.chip_dom_id("u:3") == "story-map-owner-chip-u-3"
      assert StoryMapFilter.chip_dom_id("agent") == "story-map-owner-chip-agent"
    end
  end

  describe "chips/2" do
    test "one chip per owner of a card on this map, people first and the AI last" do
      cards = [
        card(1, [human_owner(mara())]),
        card(2, [ai_owner()]),
        card(3, [human_owner(dana())]),
        card(4, [human_owner(dana())])
      ]

      assert [dana_chip, mara_chip, ai_chip] = StoryMapFilter.chips(cards, [])

      assert dana_chip.key == "u:3"
      assert dana_chip.actor == :human
      assert dana_chip.name == "Dana Kim"
      assert dana_chip.email == "dana@acme.co"
      refute dana_chip.selected?

      assert mara_chip.key == "u:4"
      assert ai_chip.key == "agent"
      assert ai_chip.actor == :ai
      assert ai_chip.name == "Relay AI"
    end

    test "a selected key with no card left still gets a chip, so it can be cleared" do
      # Without the union a selected chip vanishes while STILL filtering, leaving an empty
      # map and no obvious way back.
      chips = StoryMapFilter.chips([card(1, [human_owner(dana())])], ["u:3", "agent"])

      assert Enum.map(chips, & &1.key) == ["u:3", "agent"]
      assert Enum.all?(chips, & &1.selected?)
      assert Enum.find(chips, &(&1.key == "agent")).name == "Relay AI"
    end

    test "a selection is marked, and a forged selected key is ignored" do
      chips = StoryMapFilter.chips([card(1, [human_owner(dana())])], ["u:3", "u:nope"])

      assert [%{key: "u:3", selected?: true}] = chips
    end
  end

  describe "visible/3 — owner AND needs-input" do
    test "an empty selection means every owner" do
      cards = [card(1, [human_owner(dana())]), card(2, [ai_owner()])]

      assert StoryMapFilter.visible(cards, [], false) == cards
    end

    test "a card passes when ANY of its owners is selected" do
      # Relay cards can have several owners, unlike the artboard's single `c.owner`.
      both = card(1, [human_owner(dana()), human_owner(mara())])
      just_mara = card(2, [human_owner(mara())])

      assert StoryMapFilter.visible([both, just_mara], ["u:3"], false) == [both]
    end

    test "owner and needs-input compose with AND" do
      a = card(1, [human_owner(dana())], :needs_input)
      b = card(2, [human_owner(dana())], :working)
      c = card(3, [ai_owner()], :needs_input)

      assert StoryMapFilter.visible([a, b, c], [], true) == [a, c]
      assert StoryMapFilter.visible([a, b, c], ["u:3"], true) == [a]
    end

    test "needs-input is strictly :needs_input — a failed card is not included" do
      needs = card(1, [], :needs_input)
      failed = card(2, [], :failed)
      review = card(3, [], :in_review)

      assert StoryMapFilter.visible([needs, failed, review], [], true) == [needs]
    end

    test "an unowned card is hidden by any owner selection" do
      assert StoryMapFilter.visible([card(1, [])], ["u:3"], false) == []
    end
  end

  describe "active?/2" do
    test "is true for either filter and false for neither" do
      refute StoryMapFilter.active?([], false)
      assert StoryMapFilter.active?(["u:3"], false)
      assert StoryMapFilter.active?([], true)
      assert StoryMapFilter.active?(["u:3"], true)
    end
  end
end
