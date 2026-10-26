defmodule Schemas.BoardTest do
  use Hamaca.DataCase, async: true

  alias Schemas.Board

  describe "Board.changeset/2 + persistence" do
    test "inserts a board and applies the name/key defaults" do
      user = insert(:user)

      board =
        %Board{owner_id: user.id}
        |> Board.changeset(%{slug: "my-slug"})
        |> Repo.insert!()

      assert board.name == "My board"
      assert board.key == "RL"
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
        cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: bad, key: "RL"})
        refute cs.valid?, "expected #{inspect(bad)} to be invalid"
        assert "must be lowercase letters, numbers, and hyphens" in errors_on(cs).slug
      end
    end

    test "accepts a lowercase hyphenated slug" do
      cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: "RL"})
      assert cs.valid?
    end
  end

  describe "changeset/2 card key (RLY-230)" do
    test "accepts an exactly-2-letter key" do
      cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: "RL"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :key) == "RL"
    end

    test "upcases a lowercase key" do
      cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: "xy"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :key) == "XY"
    end

    test "strips symbols/digits, then validates the remaining letters" do
      # "R1" normalizes to "R" (one letter) -> rejected with the 2-letter message
      cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: "R1"})
      refute cs.valid?
      assert "must be exactly 2 letters" in errors_on(cs).key
    end

    test "rejects a one-letter key, a three-letter key, and a blank key" do
      for bad <- ["R", "RLY", ""] do
        cs = Board.changeset(%Board{owner_id: 1}, %{name: "B", slug: "acme-1", key: bad})
        refute cs.valid?, "expected #{inspect(bad)} to be invalid"
      end
    end
  end

  describe "archived?/1" do
    test "reflects archived_at" do
      refute Board.archived?(%Board{archived_at: nil})
      assert Board.archived?(%Board{archived_at: ~U[2026-07-08 00:00:00Z]})
    end
  end

  describe "key_from_name/1 (RE455)" do
    test "upcases and keeps the first two A–Z letters, with no fallback" do
      assert Board.key_from_name("acme checkout") == "AC"
      assert Board.key_from_name("A1") == "A"
      assert Board.key_from_name("a1c") == "AC"
      assert Board.key_from_name("42") == ""
      assert Board.key_from_name(nil) == ""
      assert Board.key_from_name("Zeta Rollout") == "ZE"
    end
  end

  describe "key_format/0 and name_max_length/0 (RE455)" do
    test "key_format/0 matches exactly two upper-case letters" do
      assert Regex.match?(Board.key_format(), "AC")
      refute Regex.match?(Board.key_format(), "A")
      refute Regex.match?(Board.key_format(), "ABC")
      refute Regex.match?(Board.key_format(), "ac")
    end

    test "name_max_length/0 is 80" do
      assert Board.name_max_length() == 80
    end

    test "changeset/2 still rejects a key that normalizes to one letter" do
      changeset = Board.changeset(%Board{owner_id: 1}, %{name: "Acme", slug: "acme", key: "a1"})

      assert "must be exactly 2 letters" in errors_on(changeset).key
    end

    test "changeset/2 still rejects an 81-character name" do
      changeset = Board.changeset(%Board{owner_id: 1}, %{name: String.duplicate("a", 81), slug: "acme", key: "AC"})

      assert errors_on(changeset).name != []
    end
  end
end
