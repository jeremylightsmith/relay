defmodule Relay.BoardsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Flows
  alias Relay.Repo
  alias Schemas.Board
  alias Schemas.Membership
  alias Schemas.Stage

  @default_hierarchical_names [
    "Backlog",
    "Next up",
    "Spec",
    "Spec:Review",
    "Spec:Done",
    "Plan",
    "Plan:Done",
    "Code",
    "Review",
    "Deploy",
    "Done"
  ]

  describe "get_or_create_default_board/1" do
    test "creates a board with defaults and the seeded stage tree, in hierarchical order" do
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
               %Stage{name: "Spec:Review", position: 9, type: :review, ai_enabled: false, category: :planning},
               %Stage{name: "Spec:Done", position: 10, type: :done, ai_enabled: false, category: :planning},
               %Stage{name: "Plan", position: 4, type: :planning, ai_enabled: true, category: :planning},
               %Stage{name: "Plan:Done", position: 11, type: :done, ai_enabled: false, category: :planning},
               %Stage{name: "Code", position: 5, type: :work, ai_enabled: true, category: :in_progress},
               %Stage{name: "Review", position: 6, type: :review, ai_enabled: false, category: :in_progress},
               %Stage{name: "Deploy", position: 7, type: :work, ai_enabled: true, category: :in_progress},
               %Stage{name: "Done", position: 8, type: :done, ai_enabled: false, category: :complete}
             ] = board.stages
    end

    test "board.stages lists each substage directly under its parent, Review before Done" do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)

      expected = @default_hierarchical_names

      assert Enum.map(board.stages, & &1.name) == expected
      assert user |> Boards.get_board!(board.slug) |> Map.fetch!(:stages) |> Enum.map(& &1.name) == expected
    end

    test "position-based terminal/next-stage logic is unchanged by the hierarchical order" do
      board = Boards.get_or_create_default_board(insert(:user))
      stages = Boards.list_stages(board)
      spec = Enum.find(stages, &(&1.name == "Spec"))

      assert Boards.terminal_stage(stages).name == "Done"
      assert Boards.next_main_stage(spec).name == "Plan"
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

      assert Enum.map(board.stages, & &1.name) == @default_hierarchical_names
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
      {:ok, a} = Boards.create_board(user, %{name: "Alpha", slug: unique_slug("alpha")})
      {:ok, b} = Boards.create_board(user, %{name: "Beta", slug: unique_slug("beta")})
      {:ok, archived} = Boards.create_board(user, %{name: "Gamma"})
      {:ok, _} = Boards.archive_board(archived)

      assert Enum.map(Boards.list_boards(user), & &1.id) == [a.id, b.id]
    end

    test "never returns another user's boards" do
      {:ok, _mine} = Boards.create_board(insert(:user), %{name: "Mine"})
      other = insert(:user)
      {:ok, theirs} = Boards.create_board(other, %{name: "Theirs", slug: unique_slug("theirs")})

      refute theirs.id in Enum.map(Boards.list_boards(insert(:user)), & &1.id)
    end

    test "returns boards the user is a member of but does not own" do
      creator = insert(:user)
      {:ok, board} = Boards.create_board(creator, %{name: "Shared"})
      guest = insert(:user)
      insert(:membership, board: board, user: guest, email: guest.email)

      assert board.id in Enum.map(Boards.list_boards(guest), & &1.id)
    end

    test "keeps creation order and the default board when a later board is starred" do
      user = insert(:user)
      {:ok, zeta} = Boards.create_board(user, %{name: "zeta", slug: unique_slug("zeta")})
      {:ok, alpha} = Boards.create_board(user, %{name: "Alpha", slug: unique_slug("alpha")})
      assert {:ok, true} = Boards.set_starred(user, alpha.slug, true)

      assert Enum.map(Boards.list_boards(user), & &1.id) == [zeta.id, alpha.id]
      assert Boards.get_or_create_default_board(user).id == zeta.id
    end
  end

  # RE395: personal stars + starred-first A–Z display order.
  defp member_board(user, name, attrs \\ []) do
    board = insert(:board, Keyword.merge([name: name], attrs))
    insert(:membership, board: board, user: user)
    board
  end

  defp display_names(user), do: Enum.map(Boards.list_boards_for_display(user), & &1.board.name)

  defp membership(user, board), do: Repo.get_by!(Membership, user_id: user.id, board_id: board.id)

  describe "list_boards_for_display/1" do
    test "orders unstarred boards A–Z case-insensitively" do
      user = insert(:user)
      for name <- ["zeta", "Alpha", "mango"], do: member_board(user, name)

      rows = Boards.list_boards_for_display(user)
      assert Enum.map(rows, & &1.board.name) == ["Alpha", "mango", "zeta"]
      assert Enum.all?(rows, &(&1.starred? == false))
    end

    test "puts a starred board first" do
      user = insert(:user)
      [zeta | _] = for name <- ["zeta", "Alpha", "mango"], do: member_board(user, name)
      assert {:ok, true} = Boards.set_starred(user, zeta.slug, true)

      rows = Boards.list_boards_for_display(user)
      assert Enum.map(rows, & &1.board.name) == ["zeta", "Alpha", "mango"]
      assert Enum.map(rows, & &1.starred?) == [true, false, false]
    end

    test "sorts starred boards A–Z, then unstarred boards A–Z" do
      user = insert(:user)
      beta = member_board(user, "Beta")
      alpha = member_board(user, "alpha")
      member_board(user, "Delta")
      member_board(user, "charlie")
      {:ok, true} = Boards.set_starred(user, beta.slug, true)
      {:ok, true} = Boards.set_starred(user, alpha.slug, true)

      assert display_names(user) == ["alpha", "Beta", "charlie", "Delta"]
    end

    test "breaks name ties by id ascending" do
      user = insert(:user)
      first = member_board(user, "Same")
      second = member_board(user, "Same")

      assert Enum.map(Boards.list_boards_for_display(user), & &1.board.id) == [first.id, second.id]
    end

    test "omits archived boards" do
      user = insert(:user)
      archived = member_board(user, "Old", archived_at: ~U[2020-01-01 00:00:00Z])

      refute archived.id in Enum.map(Boards.list_boards_for_display(user), & &1.board.id)
    end

    test "another member's star does not change your order" do
      a = insert(:user)
      b = insert(:user)
      mango = insert(:board, name: "mango")
      zeta = insert(:board, name: "zeta")
      for board <- [mango, zeta], user <- [a, b], do: insert(:membership, board: board, user: user)
      {:ok, true} = Boards.set_starred(a, zeta.slug, true)

      rows = Boards.list_boards_for_display(b)
      assert Enum.map(rows, & &1.board.name) == ["mango", "zeta"]
      assert Enum.map(rows, & &1.starred?) == [false, false]
    end
  end

  describe "set_starred/3" do
    test "sets (not toggles) the caller's star and returns the value set" do
      user = insert(:user)
      board = member_board(user, "Zeta", slug: "zeta-board")

      assert Boards.set_starred(user, "zeta-board", true) == {:ok, true}
      assert Boards.set_starred(user, "zeta-board", true) == {:ok, true}
      assert membership(user, board).starred == true

      assert Boards.set_starred(user, "zeta-board", false) == {:ok, false}
      assert membership(user, board).starred == false
    end

    test "is :not_found on a board the user is not a member of, or an unknown slug" do
      owner = insert(:user)
      theirs = member_board(owner, "Theirs", slug: "theirs")
      user = insert(:user)

      assert Boards.set_starred(user, "theirs", true) == {:error, :not_found}
      assert membership(owner, theirs).starred == false
      assert Boards.set_starred(user, "no-such-board", true) == {:error, :not_found}
    end

    test "is allowed on an archived board" do
      user = insert(:user)
      board = member_board(user, "Old", archived_at: ~U[2020-01-01 00:00:00Z])

      assert Boards.set_starred(user, board.slug, true) == {:ok, true}
    end

    test "Membership.changeset/2 never casts :starred" do
      changeset = Membership.changeset(%Membership{}, %{email: "x@example.com", starred: true})

      refute Map.has_key?(changeset.changes, :starred)
    end
  end

  # RE406: a per-member mute of the board's APNs pushes — a sibling of the personal star.
  describe "set_muted/3" do
    test "sets (not toggles) the caller's mute and returns the value set" do
      user = insert(:user)
      board = member_board(user, "Zeta", slug: "zeta-board")

      assert Boards.set_muted(user, "zeta-board", true) == {:ok, true}
      assert Boards.set_muted(user, "zeta-board", true) == {:ok, true}
      assert membership(user, board).muted == true

      assert Boards.set_muted(user, "zeta-board", false) == {:ok, false}
      assert membership(user, board).muted == false
    end

    test "is :not_found on a board the user is not a member of, or an unknown slug" do
      owner = insert(:user)
      theirs = member_board(owner, "Theirs", slug: "theirs")
      user = insert(:user)

      assert Boards.set_muted(user, "theirs", true) == {:error, :not_found}
      assert membership(owner, theirs).muted == false
      assert Boards.set_muted(user, "no-such-board", true) == {:error, :not_found}
    end

    test "changes only the caller's own membership row" do
      user = insert(:user)
      other = insert(:user)
      board = member_board(user, "Shared")
      insert(:membership, board: board, user: other)

      assert Boards.set_muted(user, board.slug, true) == {:ok, true}
      assert membership(user, board).muted == true
      assert membership(other, board).muted == false
    end

    test "muting does not move a row in the display order and is reported as muted?" do
      user = insert(:user)
      member_board(user, "beta")
      alpha = member_board(user, "Alpha")
      zeta = member_board(user, "zeta")
      {:ok, true} = Boards.set_starred(user, zeta.slug, true)

      assert {:ok, true} = Boards.set_muted(user, alpha.slug, true)

      rows = Boards.list_boards_for_display(user)
      assert Enum.map(rows, & &1.board.name) == ["zeta", "Alpha", "beta"]
      assert Enum.map(rows, & &1.muted?) == [false, true, false]
    end

    test "a brand-new membership is reported as not muted" do
      user = insert(:user)
      for name <- ["one", "two"], do: member_board(user, name)

      rows = Boards.list_boards_for_display(user)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.muted? == false))
    end

    test "Membership.changeset/2 never casts :muted" do
      changeset = Membership.changeset(%Membership{}, %{email: "x@example.com", muted: true})

      refute Map.has_key?(changeset.changes, :muted)
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
      {:ok, a} = Boards.create_board(user, %{name: "Alpha", slug: unique_slug("alpha")})
      {:ok, b} = Boards.create_board(user, %{name: "Beta", slug: unique_slug("beta")})

      assert {:error, changeset} = Boards.update_board(b, %{slug: a.slug})
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

  describe "list_scheduler_stages/1 (RE402)" do
    test "returns the board's stages as narrow %Stage{} structs in list_stages/1 order" do
      board = insert(:board)
      done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 3)
      code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 2)
      _backlog = insert(:stage, board: board, name: "Backlog", type: :queue, category: :unstarted, position: 1)
      {:ok, _review} = Boards.enable_lane(code, :review)

      result = Boards.list_scheduler_stages(board.id)
      full = Boards.list_stages(board)

      assert Enum.map(result, & &1.id) == Enum.map(full, & &1.id)
      assert Enum.all?(result, &match?(%Stage{}, &1))
      assert Boards.top_level_done_stage_ids(result) == Boards.top_level_done_stage_ids(full)
      assert Boards.top_level_done_stage_ids(result) == [done.id]
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

  describe "update_stage/2 reject_to_stage_id board scoping (RE344)" do
    setup do
      board = insert(:board)
      plan = insert(:stage, board: board, name: "Plan", type: :planning, category: :planning, position: 1)
      review = insert(:stage, board: board, name: "Review", type: :review, category: :in_progress, position: 2)
      %{plan: plan, review: review}
    end

    test "refuses another board's stage", %{review: review} do
      foreign = insert(:stage, board: insert(:board), position: 1)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Boards.update_stage(review, %{reject_to_stage_id: foreign.id})

      assert "must be a main stage on this board" in errors_on(changeset).reject_to_stage_id
      assert Repo.get!(Stage, review.id).reject_to_stage_id == nil
    end

    test "refuses a sub-lane on the same board", %{plan: plan, review: review} do
      {:ok, sublane} = Boards.enable_lane(plan, :review)

      assert {:error, %Ecto.Changeset{}} = Boards.update_stage(review, %{reject_to_stage_id: sublane.id})
      assert Repo.get!(Stage, review.id).reject_to_stage_id == nil
    end

    test "accepts a same-board main stage, and clearing to nil", %{plan: plan, review: review} do
      assert {:ok, set} = Boards.update_stage(review, %{reject_to_stage_id: plan.id})
      assert set.reject_to_stage_id == plan.id

      assert {:ok, cleared} = Boards.update_stage(set, %{reject_to_stage_id: nil})
      assert cleared.reject_to_stage_id == nil
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

    test "returns EVERY top-level complete stage, not just the terminal one" do
      # RE276's filter hides all of them, unlike `Cards.done?/2` which is the terminal stage
      # only — a board with `Shipped` + `Archive` is where the two predicates diverge.
      board = insert(:board)
      _backlog = insert(:stage, board: board, position: 1, category: :unstarted)
      shipped = insert(:stage, board: board, name: "Shipped", position: 2, category: :complete)
      archive = insert(:stage, board: board, name: "Archive", position: 3, category: :complete)

      stages = Boards.list_stages(board)
      assert Enum.sort(Boards.top_level_done_stage_ids(stages)) == Enum.sort([shipped.id, archive.id])
    end
  end

  describe "intake_stage/1" do
    test "is the first top-level stage by position, whatever it is named" do
      board = insert(:board)
      insert(:stage, board: board, name: "Code", position: 2)
      first = insert(:stage, board: board, name: "Renamed intake", position: 1)

      assert Boards.intake_stage(board).id == first.id
    end

    test "ignores sub-lanes — a column is a top-level stage" do
      board = insert(:board)
      parent = insert(:stage, board: board, name: "Spec", position: 2)
      insert(:stage, board: board, name: "Review", position: 1, parent_id: parent.id)

      assert Boards.intake_stage(board).id == parent.id
    end

    test "is nil for a board with no stages" do
      assert Boards.intake_stage(insert(:board)) == nil
    end

    test "the seeded board's intake is its first seeded stage" do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)
      [first | _rest] = Enum.filter(board.stages, &is_nil(&1.parent_id))

      assert Boards.intake_stage(board).id == first.id
    end
  end
end
