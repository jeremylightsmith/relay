defmodule Relay.BoardsGateConfigTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  setup do
    board = insert(:board)
    code = insert(:stage, board: board, name: "Code", owner: :ai, category: :in_progress, position: 1)
    review = insert(:stage, board: board, name: "Review", owner: :human, category: :in_progress, position: 2)
    deploy = insert(:stage, board: board, name: "Deploy", owner: :ai, category: :in_progress, position: 3)
    %{board: board, code: code, review: review, deploy: deploy}
  end

  describe "update_stage/2 gate config" do
    test "round-trips approval_gate and reject_to_stage_id", %{board: board, review: review, code: code} do
      assert {:ok, updated} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})
      assert updated.approval_gate
      assert updated.reject_to_stage_id == code.id

      reloaded = board |> Boards.list_stages() |> Enum.find(&(&1.id == review.id))
      assert reloaded.approval_gate
      assert reloaded.reject_to_stage_id == code.id
    end

    test "rejects a reject target on another board", %{review: review} do
      foreign = insert(:stage, board: insert(:board))

      assert {:error, changeset} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: foreign.id})
      assert %{reject_to_stage_id: ["must be a main stage on the same board"]} = errors_on(changeset)
    end

    test "rejects a sub-lane reject target", %{review: review, deploy: deploy} do
      {:ok, sublane} = Boards.enable_lane(deploy, :review)

      assert {:error, changeset} = Boards.update_stage(review, %{reject_to_stage_id: sublane.id})
      assert %{reject_to_stage_id: ["must be a main stage on the same board"]} = errors_on(changeset)
    end

    test "deleting the reject-target stage nilifies the FK", %{board: board, review: review, code: code} do
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})

      assert {:ok, _deleted} = Boards.delete_stage(code)

      reloaded = Boards.get_stage(board, review.id)
      assert reloaded.approval_gate
      assert reloaded.reject_to_stage_id == nil
    end
  end

  describe "next_main_stage/1" do
    test "returns the following main stage by position, skipping sub-lanes, or nil at the end",
         %{code: code, review: review, deploy: deploy} do
      {:ok, _sublane} = Boards.enable_lane(review, :review)

      assert Boards.next_main_stage(code).id == review.id
      assert Boards.next_main_stage(review).id == deploy.id
      assert Boards.next_main_stage(deploy) == nil
    end
  end
end
