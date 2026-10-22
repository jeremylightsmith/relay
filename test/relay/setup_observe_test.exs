defmodule Relay.SetupObserveTest do
  @moduledoc """
  RE445: the board-observed sub-steps. A flow push (`Relay.Flows.upsert_from_document/3`) ticks
  5.5 once every board flow has been pushed and is enabled; a card created in the board's first
  flow stage (`Relay.Cards.create_card/3`) ticks 5.8. Both are no-ops unless that sub-step is
  current, and neither can make the push or the create fail.
  """
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Flows.Document
  alias Relay.Setup
  alias Schemas.BoardSetupStep
  alias Schemas.Flow
  alias Schemas.Stage

  @walk ~w(2 3 4 5.1 5.2 5.3 5.4 5.5 5.6 5.7 5.8)

  # A bare-minimum board whose checklist sits on reportable step `id`.
  defp board_on!(id) do
    {:ok, board} =
      Boards.create_board(insert(:user), %{name: "Streaks", slug: unique_slug("observe"), template: "bare-minimum"})

    for prior <- Enum.take_while(@walk, &(&1 != id)), do: {:ok, _} = Setup.advance(board, prior, :done, %{})
    board
  end

  defp step(board, id), do: board |> Setup.checklist() |> Map.fetch!(:steps) |> flatten() |> Enum.find(&(&1.id == id))

  defp flatten(steps), do: Enum.flat_map(steps, &[&1 | &1.children])

  defp rows(board), do: Repo.all(from(s in BoardSetupStep, where: s.board_id == ^board.id, order_by: s.id))

  defp flow_keys(board), do: Repo.all(from(f in Flow, where: f.board_id == ^board.id, order_by: f.id, select: f.key))

  defp stage(board, name),
    do: Repo.one!(from(s in Stage, where: s.board_id == ^board.id and s.name == ^name and is_nil(s.parent_id)))

  # The flow's own canonical document, with `enabled` set to `enabled` (or removed when nil).
  defp doc(board, key, enabled) do
    doc = board |> Flows.get_flow_with_stages(key) |> Document.encode()
    if is_nil(enabled), do: Map.delete(doc, "enabled"), else: Map.put(doc, "enabled", enabled)
  end

  defp push!(board, key, enabled) do
    assert {:ok, _tag, _flow} = Flows.upsert_from_document(board, key, doc(board, key, enabled))
  end

  describe "observe_flow_push/2 via upsert_from_document/3" do
    # Scenario 12
    test "5.5 waits until every flow is pushed enabled, then finishes" do
      board = board_on!("5.5")
      assert [key1, key2] = flow_keys(board)
      assert Repo.all(from(f in Flow, where: f.board_id == ^board.id, select: f.enabled)) == [false, false]

      push!(board, key1, true)

      five_five = step(board, "5.5")
      assert five_five.status == :waiting
      assert five_five.data["pushed"] == [key1]
      assert five_five.evidence == "1 of 2 flows pushed"

      push!(board, key2, true)

      five_five = step(board, "5.5")
      assert five_five.status == :done
      assert five_five.evidence == "2 flows enabled"
      assert step(board, "5.6").status == :active
    end

    # Scenario 13
    test "flows pushed without enabling them leave 5.5 waiting" do
      board = board_on!("5.5")
      [key1, key2] = flow_keys(board)

      push!(board, key1, nil)
      push!(board, key2, nil)

      five_five = step(board, "5.5")
      assert five_five.status == :waiting
      assert Enum.sort(five_five.data["pushed"]) == Enum.sort([key1, key2])
    end

    # Scenario 14
    test "a push while 5.5 isn't current changes nothing" do
      board = board_on!("5.3")
      [key1 | _] = flow_keys(board)
      before = rows(board)

      push!(board, key1, true)
      assert rows(board) == before
    end

    test "a board with no checklist still pushes" do
      board = insert(:board)
      insert(:stage, board: board, name: "Build", type: :work, category: :in_progress)

      doc = %{
        "key" => "build",
        "isolation" => "shared_clean",
        "enabled" => true,
        "trigger" => %{"stage" => "Build"},
        "nodes" => [%{"key" => "a", "type" => "shell", "run" => "true"}],
        "edges" => [%{"from" => "start", "to" => "a"}, %{"from" => "a", "to" => "done", "on" => "succeeded"}]
      }

      assert {:ok, :created, _} = Flows.upsert_from_document(board, "build", doc)
      assert Setup.checklist(board) == nil
    end
  end

  describe "observe_card_created/1 via create_card/3" do
    # Scenario 15
    test "a card in the stage the first flow pulls from finishes 5.8 and step 5; one further right doesn't" do
      board = board_on!("5.8")

      assert {:ok, _} = Cards.create_card(stage(board, "Implement"), %{title: "x"})
      assert step(board, "5.8").status == :active

      assert {:ok, _} = Cards.create_card(stage(board, "Backlog"), %{title: "Show the longest streak"})

      five_eight = step(board, "5.8")
      assert five_eight.status == :done
      assert five_eight.evidence == "first card in Backlog"
      assert step(board, "5").status == :done
      assert step(board, "6").status == :active
    end

    test "a card in the first flow stage itself still finishes 5.8" do
      board = board_on!("5.8")

      assert {:ok, _} = Cards.create_card(stage(board, "Plan"), %{title: "Show the longest streak"})

      assert step(board, "5.8").status == :done
      assert step(board, "5.8").evidence == "first card in Plan"
    end

    # Scenario 16
    test "a card in the first flow stage while 5.7 is current changes nothing" do
      board = board_on!("5.7")
      before = rows(board)

      assert {:ok, _} = Cards.create_card(stage(board, "Plan"), %{title: "Early"})
      assert rows(board) == before
    end
  end
end
