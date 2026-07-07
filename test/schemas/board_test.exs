defmodule Schemas.BoardTest do
  use Relay.DataCase, async: true

  alias Schemas.Board

  describe "Board.changeset/2 + persistence" do
    test "inserts a board and applies the name/key defaults" do
      user = insert(:user)

      board =
        %Board{owner_id: user.id}
        |> Board.changeset(%{slug: "my-slug"})
        |> Repo.insert!()

      assert board.name == "My board"
      assert board.key == "RLY"
      assert board.slug == "my-slug"
      assert board.owner_id == user.id
    end

    test "requires a slug" do
      changeset = Board.changeset(%Board{owner_id: 1}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).slug
    end

    test "enforces unique slugs" do
      insert(:board, slug: "taken")
      user = insert(:user)

      assert {:error, changeset} =
               %Board{owner_id: user.id}
               |> Board.changeset(%{slug: "taken"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).slug
    end
  end
end
