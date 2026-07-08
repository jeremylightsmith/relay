defmodule Relay.BoardsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Schemas.Board
  alias Schemas.Stage

  describe "get_or_create_default_board/1" do
    test "creates a board with defaults and the 7 seeded stages, in position order" do
      user = insert(:user, name: "Ada Lovelace")

      board = Boards.get_or_create_default_board(user)

      assert board.owner_id == user.id
      assert board.name == "My board"
      assert board.key == "RLY"
      assert board.slug == "ada-lovelace"

      assert [
               %Stage{name: "Backlog", position: 1, owner: :human, category: :unstarted},
               %Stage{name: "Spec", position: 2, owner: :human, category: :unstarted},
               %Stage{name: "Plan", position: 3, owner: :ai, category: :planning},
               %Stage{name: "Code", position: 4, owner: :ai, category: :in_progress},
               %Stage{name: "Review", position: 5, owner: :human, category: :in_progress},
               %Stage{name: "Deploy", position: 6, owner: :ai, category: :in_progress},
               %Stage{name: "Done", position: 7, owner: :human, category: :complete}
             ] = board.stages
    end

    test "is idempotent — a second call returns the same board with no duplicates" do
      user = insert(:user)

      board1 = Boards.get_or_create_default_board(user)
      board2 = Boards.get_or_create_default_board(user)

      assert board1.id == board2.id
      assert Repo.aggregate(Board, :count) == 1
      assert Repo.aggregate(Stage, :count) == 7
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
end
