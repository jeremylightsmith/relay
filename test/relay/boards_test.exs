defmodule Relay.BoardsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Stage

  describe "get_or_create_default_board/1" do
    test "creates a board with defaults and the 8 seeded stages, in position order" do
      user = insert(:user, name: "Ada Lovelace")

      board = Boards.get_or_create_default_board(user)

      assert board.owner_id == user.id
      assert board.name == "My board"
      assert board.key == "RLY"
      assert board.slug == "ada-lovelace"

      assert [
               %Stage{name: "Backlog", position: 1, type: :queue, ai_enabled: false, category: :unstarted},
               %Stage{name: "Next up", position: 2, type: :queue, ai_enabled: false, category: :unstarted},
               %Stage{name: "Spec", position: 3, type: :planning, ai_enabled: true, category: :planning},
               %Stage{name: "Plan", position: 4, type: :planning, ai_enabled: true, category: :planning},
               %Stage{name: "Code", position: 5, type: :work, ai_enabled: true, category: :in_progress},
               %Stage{name: "Review", position: 6, type: :review, ai_enabled: false, category: :in_progress},
               %Stage{name: "Deploy", position: 7, type: :work, ai_enabled: true, category: :in_progress},
               %Stage{name: "Done", position: 8, type: :done, ai_enabled: false, category: :complete}
             ] = board.stages
    end

    test "is idempotent — a second call returns the same board with no duplicates" do
      user = insert(:user)

      board1 = Boards.get_or_create_default_board(user)
      board2 = Boards.get_or_create_default_board(user)

      assert board1.id == board2.id
      assert Repo.aggregate(Board, :count) == 1
      assert Repo.aggregate(Stage, :count) == 8
    end

    test "derives the slug from the email local part when the user has no name" do
      user = insert(:user, name: nil, email: "grace.hopper@example.com")

      board = Boards.get_or_create_default_board(user)

      assert board.slug == "grace-hopper"
    end

    test "de-duplicates slugs when two users would produce the same base slug" do
      user1 = insert(:user, name: "Ada Lovelace")
      user2 = insert(:user, name: "Ada Lovelace")

      board1 = Boards.get_or_create_default_board(user1)
      board2 = Boards.get_or_create_default_board(user2)

      assert board1.slug == "ada-lovelace"
      assert board2.slug == "ada-lovelace-2"
      refute board1.id == board2.id
    end

    test "does not return another user's board" do
      other = insert(:user)
      other_board = insert(:board, owner: other)

      user = insert(:user)
      board = Boards.get_or_create_default_board(user)

      refute board.id == other_board.id
      assert board.owner_id == user.id
    end
  end

  describe "update_board/2" do
    test "persists a new name" do
      board = Boards.get_or_create_default_board(insert(:user))

      assert {:ok, updated} = Boards.update_board(board, %{name: "Launch"})
      assert updated.name == "Launch"
      assert Repo.get!(Board, board.id).name == "Launch"
    end

    test "trims surrounding whitespace" do
      board = Boards.get_or_create_default_board(insert(:user))

      assert {:ok, updated} = Boards.update_board(board, %{name: "  Spacey  "})
      assert updated.name == "Spacey"
    end

    test "rejects a blank name and leaves the stored name unchanged" do
      board = Boards.get_or_create_default_board(insert(:user))

      assert {:error, changeset} = Boards.update_board(board, %{name: "   "})
      refute changeset.valid?
      assert Repo.get!(Board, board.id).name == "My board"
    end

    test "rejects a name longer than 80 characters" do
      board = Boards.get_or_create_default_board(insert(:user))

      assert {:error, changeset} = Boards.update_board(board, %{name: String.duplicate("a", 81)})
      refute changeset.valid?
    end

    test "updates name and slug but never key or owner_id even when supplied" do
      board = Boards.get_or_create_default_board(insert(:user))
      %{key: key, owner_id: owner_id} = board

      assert {:ok, updated} =
               Boards.update_board(board, %{
                 name: "Renamed",
                 slug: "renamed-slug",
                 key: "HAX",
                 owner_id: -1
               })

      assert updated.name == "Renamed"
      assert updated.slug == "renamed-slug"
      assert updated.key == key
      assert updated.owner_id == owner_id

      reloaded = Repo.get!(Board, board.id)
      assert reloaded.slug == "renamed-slug"
      assert reloaded.key == key
      assert reloaded.owner_id == owner_id
    end

    test "change_board/1 returns a changeset carrying the current name" do
      board = Boards.get_or_create_default_board(insert(:user))

      changeset = Boards.change_board(board)
      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_field(changeset, :name) == board.name
    end
  end

  describe "create_board/2" do
    test "creates a named board, derives slug + key, seeds 8 stages" do
      user = insert(:user)

      assert {:ok, board} = Boards.create_board(user, %{name: "Launch Board"})
      assert board.owner_id == user.id
      assert board.name == "Launch Board"
      assert board.slug == "launch-board"
      assert board.key == "LAUNC"
      assert length(board.stages) == 8

      assert Enum.map(board.stages, & &1.name) ==
               ["Backlog", "Next up", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "accepts string-keyed params (the create form)" do
      assert {:ok, board} = Boards.create_board(insert(:user), %{"name" => "Ops"})
      assert board.name == "Ops"
      assert board.key == "OPS"
    end

    test "de-duplicates the derived slug against existing boards" do
      user = insert(:user)
      {:ok, first} = Boards.create_board(user, %{name: "Ops"})
      {:ok, second} = Boards.create_board(user, %{name: "Ops"})

      assert first.slug == "ops"
      assert second.slug == "ops-2"
    end

    test "falls back to key RLY when the name has no alphanumerics" do
      assert {:ok, board} = Boards.create_board(insert(:user), %{name: "★ ☆ ★"})
      assert board.key == "RLY"
      assert board.slug == "board"
    end

    test "rejects a blank name and creates nothing" do
      user = insert(:user)
      before = Repo.aggregate(Board, :count)

      assert {:error, changeset} = Boards.create_board(user, %{name: "   "})
      refute changeset.valid?
      assert Repo.aggregate(Board, :count) == before
    end
  end

  describe "list_boards/1" do
    test "returns the user's non-archived boards, oldest first" do
      user = insert(:user)
      {:ok, a} = Boards.create_board(user, %{name: "Alpha"})
      {:ok, b} = Boards.create_board(user, %{name: "Beta"})
      {:ok, archived} = Boards.create_board(user, %{name: "Gamma"})
      {:ok, _} = Boards.archive_board(archived)

      assert Enum.map(Boards.list_boards(user), & &1.id) == [a.id, b.id]
    end

    test "never returns another user's boards" do
      {:ok, _mine} = Boards.create_board(insert(:user), %{name: "Mine"})
      other = insert(:user)
      {:ok, theirs} = Boards.create_board(other, %{name: "Theirs"})

      refute theirs.id in Enum.map(Boards.list_boards(insert(:user)), & &1.id)
    end
  end

  describe "get_board/2 and get_board!/2" do
    test "returns the owner's board by slug with stages preloaded" do
      user = insert(:user)
      {:ok, board} = Boards.create_board(user, %{name: "Ops"})

      found = Boards.get_board(user, "ops")
      assert found.id == board.id
      assert length(found.stages) == 8
    end

    test "returns an archived board (still loadable)" do
      user = insert(:user)
      {:ok, board} = Boards.create_board(user, %{name: "Ops"})
      {:ok, _} = Boards.archive_board(board)

      assert Boards.get_board(user, "ops").id == board.id
    end

    test "get_board/2 returns nil for a slug the user does not own" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})
      assert Boards.get_board(insert(:user), board.slug) == nil
    end

    test "get_board!/2 raises for a slug the user does not own" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})

      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(insert(:user), board.slug)
      end
    end
  end

  describe "update_board/2 slug validation" do
    test "rejects an invalid slug format and changes nothing" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})

      assert {:error, changeset} = Boards.update_board(board, %{slug: "Bad Slug"})
      refute changeset.valid?
      assert Repo.get!(Board, board.id).slug == board.slug
    end

    test "rejects a slug already taken by another board" do
      user = insert(:user)
      {:ok, _a} = Boards.create_board(user, %{name: "Alpha"})
      {:ok, b} = Boards.create_board(user, %{name: "Beta"})

      assert {:error, changeset} = Boards.update_board(b, %{slug: "alpha"})
      refute changeset.valid?
    end
  end

  describe "archive_board/1 and unarchive_board/1" do
    test "archive sets archived_at; unarchive clears it" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})

      assert {:ok, archived} = Boards.archive_board(board)
      assert archived.archived_at
      assert Board.archived?(archived)

      assert {:ok, restored} = Boards.unarchive_board(archived)
      assert restored.archived_at == nil
      refute Board.archived?(restored)
    end

    test "archive broadcasts {:board_updated, board} on the board topic" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})
      Relay.Events.subscribe(board.id)

      assert {:ok, _} = Boards.archive_board(board)
      assert_receive {:board_updated, %Board{archived_at: at}} when not is_nil(at)
    end
  end

  describe "update_stage/2 reject_to_stage_id" do
    test "persists reject_to_stage_id" do
      board = insert(:board)
      plan = insert(:stage, board: board, name: "Plan", type: :planning, category: :planning, position: 1)
      review = insert(:stage, board: board, name: "Review", type: :review, category: :in_progress, position: 2)

      assert {:ok, updated} = Boards.update_stage(review, %{reject_to_stage_id: plan.id})
      assert updated.reject_to_stage_id == plan.id
      assert Repo.get!(Stage, review.id).reject_to_stage_id == plan.id
    end
  end
end
