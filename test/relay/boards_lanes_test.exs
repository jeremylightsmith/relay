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

  test "enable_lane after a rename names the child after the new parent name (RE385)" do
    parent = main_stage(name: "Code")
    {:ok, _} = Boards.update_stage(parent, %{name: "Build"})
    reloaded = Relay.Repo.get!(Schemas.Stage, parent.id)

    assert {:ok, child} = Boards.enable_lane(reloaded, :review)
    assert child.name == "Build:Review"
  end

  test "sublanes/1 orders Review before Done whatever the creation order (RE385)" do
    parent = main_stage()
    {:ok, _} = Boards.enable_lane(parent, :done)
    {:ok, _} = Boards.enable_lane(parent, :review)

    assert parent |> Boards.sublanes() |> Enum.map(& &1.type) == [:review, :done]
  end

  describe "disable_lane/2 guard rails (RE384)" do
    test "refuses a lane an enabled flow lands on" do
      parent = main_stage()
      {:ok, done} = Boards.enable_lane(parent, :done)
      board = Relay.Repo.get!(Schemas.Board, parent.board_id)

      insert(:flow,
        board: board,
        key: "code",
        enabled: true,
        pulls_from_stage_id: insert(:stage, board: board, position: 50).id,
        works_in_stage_id: parent.id,
        lands_on_stage_id: done.id
      )

      assert {:error, {:in_use_by_flow, ["code"]}} = Boards.disable_lane(parent, :done)
      assert [%{type: :done}] = Boards.sublanes(parent)
    end

    test "refuses the public intake lane" do
      parent = main_stage()
      {:ok, review} = Boards.enable_lane(parent, :review)
      board = Relay.Repo.get!(Schemas.Board, parent.board_id)
      {:ok, _} = Boards.update_public_settings(board, %{public_intake_stage_id: review.id})

      assert {:error, :public_intake} = Boards.disable_lane(parent, :review)
    end

    test "an archived card keeps the lane non-empty" do
      parent = main_stage()
      {:ok, review} = Boards.enable_lane(parent, :review)
      insert(:card, stage: review, archived_at: DateTime.utc_now(:second))

      assert {:error, :not_empty} = Boards.disable_lane(parent, :review)
    end
  end

  test "enable_lane refuses a substage (RE384)" do
    parent = main_stage()
    {:ok, review} = Boards.enable_lane(parent, :review)

    assert {:error, :not_a_main_stage} = Boards.enable_lane(review, :done)
  end
end
