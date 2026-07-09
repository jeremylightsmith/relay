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

  describe "changeset/2 slug format (MMF 19)" do
    test "rejects a slug with uppercase, spaces, or symbols" do
      for bad <- ["Bad Slug", "acme/product", "under_score", "-leading", "trailing-"] do
        cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: bad, key: "B"})
        refute cs.valid?, "expected #{inspect(bad)} to be invalid"
        assert "must be lowercase letters, numbers, and hyphens" in errors_on(cs).slug
      end
    end

    test "accepts a lowercase hyphenated slug" do
      cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: "B"})
      assert cs.valid?
    end
  end

  describe "archived?/1" do
    test "reflects archived_at" do
      refute Board.archived?(%Board{archived_at: nil})
      assert Board.archived?(%Board{archived_at: ~U[2026-07-08 00:00:00Z]})
    end
  end
end
