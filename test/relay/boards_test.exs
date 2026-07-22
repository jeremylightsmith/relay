defmodule Relay.BoardsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Stage

  describe "get_or_create_default_board/1" do
    test "creates a board with defaults and the seeded stage tree, in position order" do
      user = insert(:user, name: "Ada Lovelace")

      board = Boards.get_or_create_default_board(user)

      assert board.owner_id == user.id
      assert board.name == "My board"
      assert board.key == "MY"
      assert board.slug == "ada-lovelace"

      assert [
               %Stage{name: "Backlog", position: 1, type: :queue, ai_enabled: false, category: :unstarted},
               %Stage{name: "Next up", position: 2, type: :queue, ai_enabled: false, category: :unstarted},
               %Stage{name: "Spec", position: 3, type: :planning, ai_enabled: true, category: :planning},
               %Stage{name: "Plan", position: 4, type: :planning, ai_enabled: true, category: :planning},
               %Stage{name: "Code", position: 5, type: :work, ai_enabled: true, category: :in_progress},
               %Stage{name: "Review", position: 6, type: :review, ai_enabled: false, category: :in_progress},
               %Stage{name: "Deploy", position: 7, type: :work, ai_enabled: true, category: :in_progress},
               %Stage{name: "Done", position: 8, type: :done, ai_enabled: false, category: :complete},
               %Stage{name: "Spec:Review", position: 9, type: :review, ai_enabled: false, category: :planning},
               %Stage{name: "Spec:Done", position: 10, type: :done, ai_enabled: false, category: :planning},
               %Stage{name: "Plan:Done", position: 11, type: :done, ai_enabled: false, category: :planning}
             ] = board.stages
    end

    test "is idempotent — a second call returns the same board with no duplicates" do
      user = insert(:user)

      board1 = Boards.get_or_create_default_board(user)
      board2 = Boards.get_or_create_default_board(user)

      assert board1.id == board2.id
      assert Repo.aggregate(Board, :count) == 1
      assert Repo.aggregate(Stage, :count) == 11
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

    test "seeds Review.reject_to → Plan so a code reject re-plans (RLY-216)" do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)

      review = Enum.find(board.stages, &(&1.name == "Review"))
      plan = Enum.find(board.stages, &(&1.name == "Plan"))

      assert review.reject_to_stage_id == plan.id
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

    test "updates name, slug, and key but never owner_id even when supplied" do
      board = Boards.get_or_create_default_board(insert(:user))
      %{owner_id: owner_id} = board

      assert {:ok, updated} =
               Boards.update_board(board, %{
                 name: "Renamed",
                 slug: "renamed-slug",
                 key: "hx",
                 owner_id: -1
               })

      assert updated.name == "Renamed"
      assert updated.slug == "renamed-slug"
      assert updated.key == "HX"
      assert updated.owner_id == owner_id

      reloaded = Repo.get!(Board, board.id)
      assert reloaded.slug == "renamed-slug"
      assert reloaded.key == "HX"
      assert reloaded.owner_id == owner_id
    end

    test "rejects an invalid key and leaves the stored key unchanged" do
      board = Boards.get_or_create_default_board(insert(:user))
      %{key: key} = board

      assert {:error, changeset} = Boards.update_board(board, %{key: "ABC"})
      refute changeset.valid?
      assert Repo.get!(Board, board.id).key == key
    end

    test "change_board/1 returns a changeset carrying the current name" do
      board = Boards.get_or_create_default_board(insert(:user))

      changeset = Boards.change_board(board)
      assert %Ecto.Changeset{} = changeset
      assert Ecto.Changeset.get_field(changeset, :name) == board.name
    end
  end

  describe "create_board/2" do
    test "creates the creator's membership" do
      user = insert(:user)
      {:ok, board} = Boards.create_board(user, %{name: "Ops"})

      assert Relay.Members.member?(board, user)
    end

    test "creates a named board, derives slug + key, seeds 11 stages (8 mains + 3 sub-lanes)" do
      user = insert(:user)

      assert {:ok, board} = Boards.create_board(user, %{name: "Launch Board"})
      assert board.owner_id == user.id
      assert board.name == "Launch Board"
      assert board.slug == "launch-board"
      assert board.key == "LA"
      assert length(board.stages) == 11

      assert Enum.map(board.stages, & &1.name) ==
               [
                 "Backlog",
                 "Next up",
                 "Spec",
                 "Plan",
                 "Code",
                 "Review",
                 "Deploy",
                 "Done",
                 "Spec:Review",
                 "Spec:Done",
                 "Plan:Done"
               ]
    end

    test "accepts string-keyed params (the create form)" do
      assert {:ok, board} = Boards.create_board(insert(:user), %{"name" => "Ops"})
      assert board.name == "Ops"
      assert board.key == "OP"
    end

    test "derives the key from the first two letters of the name, uppercased" do
      user = insert(:user)

      {:ok, board} = Boards.create_board(user, %{name: "Payments"})
      assert board.key == "PA"
    end

    test "falls back to RL when the name yields fewer than two letters" do
      user = insert(:user)

      {:ok, board} = Boards.create_board(user, %{name: "7!"})
      assert board.key == "RL"
    end

    test "de-duplicates the derived slug against existing boards" do
      user = insert(:user)
      {:ok, first} = Boards.create_board(user, %{name: "Ops"})
      {:ok, second} = Boards.create_board(user, %{name: "Ops"})

      assert first.slug == "ops"
      assert second.slug == "ops-2"
    end

    test "falls back to key RL when the name has no alphanumerics" do
      assert {:ok, board} = Boards.create_board(insert(:user), %{name: "★ ☆ ★"})
      assert board.key == "RL"
      assert board.slug == "board"
    end

    test "rejects a blank name and creates nothing" do
      user = insert(:user)
      before = Repo.aggregate(Board, :count)

      assert {:error, changeset} = Boards.create_board(user, %{name: "   "})
      refute changeset.valid?
      assert Repo.aggregate(Board, :count) == before
    end

    test "seeds the three default flows, disabled, with fully-resolved triggers" do
      user = insert(:user)
      {:ok, board} = Boards.create_board(user, %{name: "Flows AC"})

      stage_ids = MapSet.new(board.stages, & &1.id)
      stage_id = fn name -> Enum.find(board.stages, &(&1.name == name)).id end

      assert [%{key: "code"} = code, %{key: "plan"} = plan, %{key: "spec"} = spec] =
               Flows.list_flows(board)

      refute Enum.any?([code, plan, spec], & &1.enabled)

      for flow <- [code, plan, spec],
          trigger_id <- [flow.pulls_from_stage_id, flow.works_in_stage_id, flow.lands_on_stage_id] do
        assert trigger_id in stage_ids
      end

      assert spec.pulls_from_stage_id == stage_id.("Next up")
      assert spec.works_in_stage_id == stage_id.("Spec")
      assert spec.lands_on_stage_id == stage_id.("Spec:Review")
      assert plan.pulls_from_stage_id == stage_id.("Spec:Done")
      assert plan.works_in_stage_id == stage_id.("Plan")
      assert plan.lands_on_stage_id == stage_id.("Plan:Done")
      assert code.pulls_from_stage_id == stage_id.("Plan:Done")
      assert code.works_in_stage_id == stage_id.("Code")
      assert code.lands_on_stage_id == stage_id.("Review")
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

    test "returns boards the user is a member of but does not own" do
      creator = insert(:user)
      {:ok, board} = Boards.create_board(creator, %{name: "Shared"})
      guest = insert(:user)
      insert(:membership, board: board, user: guest, email: guest.email)

      assert board.id in Enum.map(Boards.list_boards(guest), & &1.id)
    end
  end

  describe "get_board/2 and get_board!/2" do
    test "returns the owner's board by slug with stages preloaded" do
      user = insert(:user)
      {:ok, board} = Boards.create_board(user, %{name: "Ops"})

      found = Boards.get_board(user, "ops")
      assert found.id == board.id
      assert length(found.stages) == 11
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

    test "get_board!/2 raises for an invited-but-unresolved member (no user_id yet)" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})
      invitee = insert(:user)
      insert(:membership, board: board, user: nil, email: invitee.email)

      assert_raise Ecto.NoResultsError, fn ->
        Boards.get_board!(invitee, board.slug)
      end
    end

    test "a member (non-owner) can load the board by slug" do
      {:ok, board} = Boards.create_board(insert(:user), %{name: "Ops"})
      guest = insert(:user)
      insert(:membership, board: board, user: guest, email: guest.email)

      assert Boards.get_board!(guest, board.slug).id == board.id
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

  describe "update_stage/2 collapsed_by_default" do
    test "persists collapsed_by_default" do
      board = insert(:board)
      backlog = insert(:stage, board: board, name: "Backlog", type: :queue, category: :unstarted, position: 1)

      assert {:ok, updated} = Boards.update_stage(backlog, %{collapsed_by_default: true})
      assert updated.collapsed_by_default
      assert Repo.get!(Stage, backlog.id).collapsed_by_default

      assert {:ok, cleared} = Boards.update_stage(updated, %{collapsed_by_default: false})
      refute cleared.collapsed_by_default
    end

    test "is not forced false for non-work stage types (unlike ai_enabled)" do
      board = insert(:board)
      done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 1)
      review = insert(:stage, board: board, name: "Review", type: :review, category: :in_progress, position: 2)

      assert {:ok, %Stage{collapsed_by_default: true}} =
               Boards.update_stage(done, %{collapsed_by_default: true})

      assert {:ok, %Stage{collapsed_by_default: true}} =
               Boards.update_stage(review, %{collapsed_by_default: true})
    end
  end

  describe "top_level_done_stage_ids/1" do
    test "returns top-level complete-stage ids, excluding done sub-lanes" do
      board = insert(:board)
      _backlog = insert(:stage, board: board, position: 1, category: :unstarted)
      code = insert(:stage, board: board, position: 2, category: :in_progress)
      done = insert(:stage, board: board, position: 3, category: :complete)
      _done_sub = insert(:stage, board: board, position: 4, category: :complete, type: :done, parent: code)

      stages = Boards.list_stages(board)
      assert Boards.top_level_done_stage_ids(stages) == [done.id]
    end
  end
end
