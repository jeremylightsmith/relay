defmodule Relay.BoardsLanesTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  defp main_stage(attrs \\ []) do
    board = insert(:board)

    insert(
      :stage,
      Keyword.merge(
        [board: board, name: "Code", type: :work, ai_enabled: true, category: :in_progress, position: 1],
        attrs
      )
    )
  end

  test "enable_lane creates a review child, ai_enabled false" do
    parent = main_stage()
    assert {:ok, child} = Boards.enable_lane(parent, :review)
    assert child.parent_id == parent.id
    assert child.type == :review
    assert child.ai_enabled == false
    assert child.category == parent.category
  end

  test "enable_lane's done child is also ai_enabled false" do
    parent = main_stage(ai_enabled: true)
    assert {:ok, child} = Boards.enable_lane(parent, :done)
    assert child.type == :done
    assert child.ai_enabled == false
  end

  test "enable_lane is idempotent" do
    parent = main_stage()
    {:ok, first} = Boards.enable_lane(parent, :review)
    {:ok, second} = Boards.enable_lane(parent, :review)
    assert first.id == second.id
  end

  test "sublanes/1 returns review then done" do
    parent = main_stage()
    {:ok, _} = Boards.enable_lane(parent, :done)
    {:ok, _} = Boards.enable_lane(parent, :review)
    assert [%{type: :review}, %{type: :done}] = Boards.sublanes(parent)
  end

  test "disable_lane removes an empty lane, guards a non-empty one" do
    parent = main_stage()
    {:ok, _review} = Boards.enable_lane(parent, :review)

    assert {:ok, :disabled} = Boards.disable_lane(parent, :review)
    assert Boards.sublanes(parent) == []
    assert {:ok, :not_enabled} = Boards.disable_lane(parent, :done)

    {:ok, review2} = Boards.enable_lane(parent, :review)
    insert(:card, stage: review2)
    assert {:error, :not_empty} = Boards.disable_lane(parent, :review)
    assert [%{type: :review}] = Boards.sublanes(parent)
  end

  test "top_level_stage returns the stage itself for a main lane, the parent for a sub-lane" do
    parent = main_stage()
    {:ok, review} = Boards.enable_lane(parent, :review)

    assert Boards.top_level_stage(parent).id == parent.id
    assert Boards.top_level_stage(review).id == parent.id
    assert Boards.top_level_stage(review).name == "Code"
    assert Boards.top_level_stage(review).type == :work
  end
end
