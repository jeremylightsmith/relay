defmodule Relay.CardsContractFieldsTest do
  @moduledoc """
  RE244 §3. "Is this contract field satisfied on this card" is a Cards concern — the run-time
  half of a flow node's declared `writes`.
  """
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Relay.Repo

  defp card(attrs \\ %{}) do
    board = insert(:board)
    stage = insert(:stage, board: board, name: "Next up", position: 1)
    {:ok, card} = Cards.create_card(stage, Map.merge(%{title: "contract"}, attrs))
    Repo.preload(card, :sub_tasks)
  end

  test "returns only the blank fields, preserving the order given" do
    card = card(%{spec: "written", plan: nil})

    assert Cards.blank_contract_fields(card, [:plan, :spec, :branch]) == [:plan, :branch]
    assert Cards.blank_contract_fields(card, [:spec]) == []
  end

  test "a nil or whitespace-only string field is blank" do
    assert Cards.blank_contract_fields(card(%{spec: nil}), [:spec]) == [:spec]
    assert Cards.blank_contract_fields(card(%{spec: "   \n\t "}), [:spec]) == [:spec]
    assert Cards.blank_contract_fields(card(%{spec: " x "}), [:spec]) == []
  end

  test "an empty ai_result map is blank" do
    assert Cards.blank_contract_fields(card(%{ai_result: nil}), [:ai_result]) == [:ai_result]
    assert Cards.blank_contract_fields(card(%{ai_result: %{}}), [:ai_result]) == [:ai_result]
    assert Cards.blank_contract_fields(card(%{ai_result: %{"summary" => "ok"}}), [:ai_result]) == []
  end

  test "sub_tasks is blank when empty and satisfied once seeded" do
    card = card()
    assert Cards.blank_contract_fields(card, [:sub_tasks]) == [:sub_tasks]

    {:ok, _} = Cards.set_sub_tasks(card, [%{title: "Alpha"}])
    assert Cards.blank_contract_fields(Repo.preload(card, :sub_tasks, force: true), [:sub_tasks]) == []
  end

  # Silently reporting "blank" for an unloaded association would fail an honest node.
  # `Cards.create_card/2` always preloads `sub_tasks` (cards travel with theirs), so an
  # unloaded association only shows up on a card fetched without that preload — build the
  # struct directly via the factory rather than through `Cards.create_card/2`.
  test "an unloaded sub_tasks association raises rather than reporting blank" do
    card = insert(:card)

    assert_raise ArgumentError, ~r/sub_tasks/, fn ->
      Cards.blank_contract_fields(card, [:sub_tasks])
    end
  end
end
