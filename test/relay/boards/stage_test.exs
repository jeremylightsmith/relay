defmodule Relay.Boards.StageTest do
  use Relay.DataCase, async: true

  alias Relay.Boards.Stage

  describe "Stage.changeset/2 + persistence" do
    test "inserts a stage with enum category and owner" do
      stage = insert(:stage, name: "Backlog", position: 1, category: :unstarted, owner: :human)

      reloaded = Repo.get!(Stage, stage.id)
      assert reloaded.name == "Backlog"
      assert reloaded.position == 1
      assert reloaded.category == :unstarted
      assert reloaded.owner == :human
    end

    test "requires name, position, category, and owner" do
      changeset = Stage.changeset(%Stage{board_id: 1}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.position
      assert "can't be blank" in errors.category
      assert "can't be blank" in errors.owner
    end

    test "rejects values outside the category and owner enums" do
      changeset =
        Stage.changeset(%Stage{board_id: 1}, %{name: "X", position: 1, category: "bogus", owner: "robot"})

      errors = errors_on(changeset)
      assert "is invalid" in errors.category
      assert "is invalid" in errors.owner
    end

    test "enforces unique position per board" do
      board = insert(:board)
      insert(:stage, board: board, position: 1)

      assert {:error, changeset} =
               %Stage{board_id: board.id}
               |> Stage.changeset(%{name: "Dup", position: 1, category: :unstarted, owner: :human})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).position
    end

    test "allows the same position on different boards" do
      insert(:stage, position: 1)
      stage = insert(:stage, position: 1)

      assert stage.id
    end
  end
end
