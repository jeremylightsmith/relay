defmodule Relay.CardsTest do
  use Relay.DataCase, async: true

  alias Relay.Cards
  alias Schemas.Board
  alias Schemas.Card

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    %{board: board, stage: stage}
  end

  describe "create_card/3" do
    test "creates a card in the stage with the given title", %{board: board, stage: stage} do
      assert {:ok, %Card{} = card} = Cards.create_card(stage, %{title: "Ship MMF 03"})

      assert card.title == "Ship MMF 03"
      assert card.stage_id == stage.id
      assert card.board_id == board.id
      assert card.tag == nil
      assert card.ref_number == 1
      assert card.position == 1
    end

    test "assigns sequential per-board refs and persists the bumped card_seq",
         %{board: board, stage: stage} do
      {:ok, card1} = Cards.create_card(stage, %{title: "First"})
      {:ok, card2} = Cards.create_card(stage, %{title: "Second"})
      {:ok, card3} = Cards.create_card(stage, %{title: "Third"})

      assert Enum.map([card1, card2, card3], & &1.ref_number) == [1, 2, 3]
      assert Cards.ref(board, card3) == "RLY-3"
      assert Repo.get!(Board, board.id).card_seq == 3
    end

    test "ref sequences are independent across boards", %{stage: stage} do
      other_board = insert(:board, key: "OPS")
      other_stage = insert(:stage, board: other_board, position: 1)

      {:ok, _a1} = Cards.create_card(stage, %{title: "A1"})
      {:ok, a2} = Cards.create_card(stage, %{title: "A2"})
      {:ok, b1} = Cards.create_card(other_stage, %{title: "B1"})

      assert a2.ref_number == 2
      assert b1.ref_number == 1
      assert Cards.ref(other_board, b1) == "OPS-1"
    end

    test "appends each new card at the bottom of its stage", %{board: board, stage: stage} do
      other_stage = insert(:stage, board: board, position: 2)

      {:ok, c1} = Cards.create_card(stage, %{title: "A"})
      {:ok, c2} = Cards.create_card(stage, %{title: "B"})
      {:ok, c3} = Cards.create_card(other_stage, %{title: "C"})

      assert c1.position == 1
      assert c2.position == 2
      assert c3.position == 1
      assert c3.ref_number == 3
    end

    test "returns an error changeset and leaves no ref gap on a blank title",
         %{board: board, stage: stage} do
      assert {:error, changeset} = Cards.create_card(stage, %{title: ""})

      assert "can't be blank" in errors_on(changeset).title
      assert Repo.aggregate(Card, :count) == 0
      assert Repo.get!(Board, board.id).card_seq == 0

      {:ok, card} = Cards.create_card(stage, %{title: "After the failure"})
      assert card.ref_number == 1
    end

    # Under the SQL sandbox all tasks funnel through the test's connection,
    # so this exercises interleaved allocation; the FOR UPDATE board-row
    # lock additionally serializes truly concurrent connections in prod.
    test "near-simultaneous creates get distinct, gap-free refs", %{stage: stage} do
      refs =
        1..8
        |> Task.async_stream(
          fn i ->
            {:ok, card} = Cards.create_card(stage, %{title: "Card #{i}"})
            card.ref_number
          end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, ref_number} -> ref_number end)

      assert Enum.sort(refs) == Enum.to_list(1..8)
    end
  end

  describe "list_cards/1" do
    test "returns the board's cards ordered by stage then position", %{board: board, stage: stage} do
      stage2 = insert(:stage, board: board, position: 2)

      {:ok, a1} = Cards.create_card(stage, %{title: "A1"})
      {:ok, b1} = Cards.create_card(stage2, %{title: "B1"})
      {:ok, a2} = Cards.create_card(stage, %{title: "A2"})

      assert Enum.map(Cards.list_cards(board), & &1.id) == [a1.id, a2.id, b1.id]
    end

    test "orders within a stage by position, not insertion order", %{board: board, stage: stage} do
      second = insert(:card, stage: stage, title: "Second", position: 2, ref_number: 2)
      first = insert(:card, stage: stage, title: "First", position: 1, ref_number: 1)

      assert Enum.map(Cards.list_cards(board), & &1.id) == [first.id, second.id]
    end

    test "does not include another board's cards", %{board: board, stage: stage} do
      other_stage = insert(:stage)
      {:ok, _theirs} = Cards.create_card(other_stage, %{title: "Elsewhere"})
      {:ok, mine} = Cards.create_card(stage, %{title: "Mine"})

      assert Enum.map(Cards.list_cards(board), & &1.id) == [mine.id]
    end
  end

  describe "update_card/2" do
    test "updates title, description, and tag", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Before"})

      assert {:ok, %Card{} = updated} =
               Cards.update_card(card, %{
                 title: "After",
                 description: "Line one\n\nLine two",
                 tag: "infra"
               })

      assert updated.title == "After"
      assert updated.description == "Line one\n\nLine two"
      assert updated.tag == "infra"
      assert Repo.get!(Card, card.id).description == "Line one\n\nLine two"
    end

    test "rejects a blank title and persists nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Keep me"})

      assert {:error, changeset} = Cards.update_card(card, %{title: ""})
      assert "can't be blank" in errors_on(changeset).title
      assert Repo.get!(Card, card.id).title == "Keep me"
    end

    test "clearing the description stores nil", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.update_card(card, %{description: "something"})

      assert {:ok, updated} = Cards.update_card(card, %{description: ""})
      assert updated.description == nil
    end

    test "never changes board_id, stage_id, position, or ref_number", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Pinned"})

      assert {:ok, updated} =
               Cards.update_card(card, %{
                 title: "Still pinned",
                 board_id: card.board_id + 1,
                 stage_id: card.stage_id + 1,
                 position: 99,
                 ref_number: 99
               })

      assert updated.board_id == card.board_id
      assert updated.stage_id == card.stage_id
      assert updated.position == card.position
      assert updated.ref_number == card.ref_number
    end

    test "persists branch and plan and they survive a reload", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Runner card"})

      assert {:ok, %Card{} = updated} =
               Cards.update_card(card, %{
                 branch: "rly-21-card-branch-plan",
                 plan: "## Task 1\n\n- [ ] add the fields"
               })

      assert updated.branch == "rly-21-card-branch-plan"
      assert updated.plan == "## Task 1\n\n- [ ] add the fields"

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.branch == "rly-21-card-branch-plan"
      assert reloaded.plan == "## Task 1\n\n- [ ] add the fields"
    end

    test "setting branch and plan never touches the programmatic fields", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Pinned"})

      assert {:ok, updated} =
               Cards.update_card(card, %{
                 branch: "rly-21-card-branch-plan",
                 plan: "the plan",
                 board_id: card.board_id + 1,
                 stage_id: card.stage_id + 1,
                 position: 99,
                 ref_number: 99
               })

      assert updated.branch == "rly-21-card-branch-plan"
      assert updated.plan == "the plan"
      assert updated.board_id == card.board_id
      assert updated.stage_id == card.stage_id
      assert updated.position == card.position
      assert updated.ref_number == card.ref_number
    end
  end

  describe "get_card_by_ref/2" do
    test "returns the card the ref points at on the board", %{board: board, stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Find me"})

      assert %Card{id: id} = Cards.get_card_by_ref(board, "RLY-1")
      assert id == card.id
    end

    test "returns nil for an unknown ref number", %{board: board} do
      assert Cards.get_card_by_ref(board, "RLY-99") == nil
    end

    test "returns nil for malformed or foreign-key refs", %{board: board, stage: stage} do
      {:ok, _card} = Cards.create_card(stage, %{title: "Here"})

      for ref <- ["", "RLY", "RLY-", "RLY-abc", "RLY-1extra", "RLY--1", "RLY-0", "OPS-1", "rly-1"] do
        assert Cards.get_card_by_ref(board, ref) == nil, "expected nil for #{inspect(ref)}"
      end
    end

    test "never returns another board's card", %{board: board} do
      other_stage = insert(:stage)

      {:ok, _theirs} = Cards.create_card(other_stage, %{title: "Theirs"})

      assert Cards.get_card_by_ref(board, "RLY-1") == nil
    end
  end

  describe "move_card/4" do
    setup %{board: board} do
      %{target: insert(:stage, board: board, position: 2)}
    end

    test "moves a card to another stage at the index, reindexing the target gap-free",
         %{board: board, stage: stage, target: target} do
      # Gappy target positions prove the whole target stage is re-indexed.
      a = insert(:card, stage: target, title: "A", position: 3, ref_number: 10)
      b = insert(:card, stage: target, title: "B", position: 7, ref_number: 11)
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      assert {:ok, %Card{} = moved} = Cards.move_card(card, target, 1)

      assert moved.stage_id == target.id
      assert moved.position == 2
      assert stage_card_ids(board, target) == [a.id, moved.id, b.id]
      assert stage_positions(board, target) == [1, 2, 3]
    end

    test "index 0 inserts at the top of the target stage",
         %{board: board, stage: stage, target: target} do
      existing = insert(:card, stage: target, title: "Existing", position: 1, ref_number: 10)
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      assert {:ok, moved} = Cards.move_card(card, target, 0)

      assert stage_card_ids(board, target) == [moved.id, existing.id]
      assert stage_positions(board, target) == [1, 2]
    end

    test "an index past the end and a negative index clamp into range",
         %{board: board, stage: stage, target: target} do
      existing = insert(:card, stage: target, title: "Existing", position: 1, ref_number: 10)
      {:ok, card_a} = Cards.create_card(stage, %{title: "Bottom"})
      {:ok, card_b} = Cards.create_card(stage, %{title: "Top"})

      {:ok, bottom} = Cards.move_card(card_a, target, 99)
      {:ok, top} = Cards.move_card(card_b, target, -5)

      assert stage_card_ids(board, target) == [top.id, existing.id, bottom.id]
      assert stage_positions(board, target) == [1, 2, 3]
    end

    test "reorders within the same stage keeping positions contiguous",
         %{board: board, stage: stage} do
      {:ok, first} = Cards.create_card(stage, %{title: "First"})
      {:ok, second} = Cards.create_card(stage, %{title: "Second"})
      {:ok, third} = Cards.create_card(stage, %{title: "Third"})

      assert {:ok, moved} = Cards.move_card(third, stage, 0)

      assert moved.stage_id == stage.id
      assert stage_card_ids(board, stage) == [moved.id, first.id, second.id]
      assert stage_positions(board, stage) == [1, 2, 3]
    end

    test "moving into an empty stage lands at position 1", %{stage: stage, target: target} do
      {:ok, card} = Cards.create_card(stage, %{title: "Loner"})

      assert {:ok, moved} = Cards.move_card(card, target, 0)

      assert moved.stage_id == target.id
      assert moved.position == 1
    end

    test "refuses a target stage on another board", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Stay"})
      foreign_stage = insert(:stage)

      assert_raise FunctionClauseError, fn -> Cards.move_card(card, foreign_stage, 0) end
      assert Repo.get!(Card, card.id).stage_id == stage.id
    end
  end

  describe "set_status/3" do
    test "sets status and progress and preloads owners", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:ok, %Card{} = updated} =
               Cards.set_status(card, %{"status" => "working", "progress" => "40"})

      assert updated.status == :working
      assert updated.progress == 40
      assert updated.owners == []
      assert Repo.get!(Card, card.id).status == :working
    end

    test "returns an error changeset and persists nothing on invalid input", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:error, %Ecto.Changeset{}} = Cards.set_status(card, %{"status" => "banana"})

      assert {:error, %Ecto.Changeset{}} =
               Cards.set_status(card, %{"status" => "working", "progress" => "250"})

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.status == :queued
      assert reloaded.progress == nil
    end
  end

  describe "owner management" do
    setup %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Owned"})
      %{card: card, user: insert(:user)}
    end

    test "add_owner/3 with {:user, id} adds a human owner with the user preloaded",
         %{card: card, user: user} do
      assert {:ok, %Card{} = updated} = Cards.add_owner(card, {:user, user.id})

      assert [owner] = updated.owners
      assert owner.actor_type == :user
      assert owner.user_id == user.id
      assert owner.user.id == user.id
    end

    test "add_owner/3 with :agent adds the AI owner", %{card: card} do
      assert {:ok, %Card{} = updated} = Cards.add_owner(card, :agent)

      assert [owner] = updated.owners
      assert owner.actor_type == :agent
      assert owner.user_id == nil
    end

    test "add_owner/3 is idempotent", %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, updated} = Cards.add_owner(card, {:user, user.id})
      {:ok, _card} = Cards.add_owner(card, :agent)
      {:ok, updated_again} = Cards.add_owner(card, :agent)

      assert length(updated.owners) == 1
      assert length(updated_again.owners) == 2
    end

    test "add_owner/3 returns an error changeset for an unknown user id", %{card: card} do
      assert {:error, %Ecto.Changeset{}} = Cards.add_owner(card, {:user, -1})
      assert {:ok, %Card{owners: []}} = Cards.set_owners(card, [])
    end

    test "remove_owner/3 removes only the matching actor and is idempotent",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, _card} = Cards.add_owner(card, :agent)

      assert {:ok, %Card{} = updated} = Cards.remove_owner(card, :agent)
      assert [%{actor_type: :user}] = updated.owners

      assert {:ok, %Card{} = again} = Cards.remove_owner(card, :agent)
      assert [%{actor_type: :user}] = again.owners

      assert {:ok, %Card{owners: []}} = Cards.remove_owner(card, {:user, user.id})
    end

    test "set_owners/3 replaces the owner list atomically", %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      assert {:ok, %Card{} = updated} = Cards.set_owners(card, [{:user, user.id}])

      assert [owner] = updated.owners
      assert owner.actor_type == :user
      assert owner.user_id == user.id
    end

    test "set_owners/3 rolls back on an invalid actor, keeping existing owners",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      assert {:error, %Ecto.Changeset{}} = Cards.set_owners(card, [:agent, {:user, -1}])

      assert {:ok, %Card{} = reloaded} = Cards.remove_owner(card, :agent)
      assert [%{actor_type: :user}] = reloaded.owners
    end
  end

  describe "active_owner_type/1" do
    setup %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Baton"})
      %{card: card, user: insert(:user)}
    end

    test "returns nil for an unowned card", %{card: card} do
      assert Cards.active_owner_type(card) == nil
    end

    test "returns :human when only user owners", %{card: card, user: user} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})

      assert Cards.active_owner_type(card) == :human
    end

    test "returns :ai when the agent is among the owners, even with humans",
         %{card: card, user: user} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})
      {:ok, card} = Cards.add_owner(card, :agent)

      assert Cards.active_owner_type(card) == :ai
    end
  end

  describe "activity logging" do
    setup %{board: board} do
      user = insert(:user, name: "Ada Lovelace")
      target = insert(:stage, board: board, name: "Code", position: 2)
      %{user: user, target: target}
    end

    test "create_card/3 logs :created attributed to the actor", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"}, {:user, user.id})

      assert [%Schemas.Activity{type: :created, actor_type: :user, user_id: user_id, meta: %{}}] =
               activities(card)

      assert user_id == user.id
    end

    test "create_card/3 defaults the actor to the agent", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert [%Schemas.Activity{type: :created, actor_type: :agent, user_id: nil}] = activities(card)
    end

    test "a failed create logs nothing", %{stage: stage} do
      {:error, _changeset} = Cards.create_card(stage, %{title: ""})

      assert Repo.aggregate(Schemas.Activity, :count) == 0
    end

    test "move_card/4 logs :moved with both stage names", %{stage: stage, target: target, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      {:ok, moved} = Cards.move_card(card, target, 0, {:user, user.id})

      assert [_created, %Schemas.Activity{type: :moved, actor_type: :user, meta: meta}] =
               activities(moved)

      assert meta == %{"from_stage" => stage.name, "to_stage" => "Code"}
    end

    test "move_card/4 into a sub-lane snapshots the human label, not the composite Stage.name",
         %{stage: stage, target: target} do
      {:ok, review} = Relay.Boards.enable_lane(target, :review)
      {:ok, card} = Cards.create_card(stage, %{title: "Reviewable"})

      {:ok, moved} = Cards.move_card(card, review, 0)

      assert [_created, %Schemas.Activity{type: :moved, meta: meta}] = activities(moved)
      assert meta == %{"from_stage" => stage.name, "to_stage" => "Code · Review"}
    end

    test "a same-stage reorder logs nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "A"})
      {:ok, _other} = Cards.create_card(stage, %{title: "B"})

      {:ok, moved} = Cards.move_card(card, stage, 1)

      assert [%Schemas.Activity{type: :created}] = activities(moved)
    end

    test "set_status/3 logs :status_changed with from/to", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      {:ok, updated} = Cards.set_status(card, %{"status" => "in_review"}, {:user, user.id})

      assert [_created, %Schemas.Activity{type: :status_changed, actor_type: :user, meta: meta}] =
               activities(updated)

      assert meta == %{"from_status" => "queued", "to_status" => "in_review"}
    end

    test "a progress-only change does not log", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.set_status(card, %{"status" => "working", "progress" => "10"})

      {:ok, card} = Cards.set_status(card, %{"status" => "working", "progress" => "50"})

      assert Enum.map(activities(card), & &1.type) == [:created, :status_changed]
    end

    test "a failed status change logs nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      {:error, _changeset} = Cards.set_status(card, %{"status" => "banana"})

      assert Enum.map(activities(card), & &1.type) == [:created]
    end

    test "add_owner/3 logs :owners_changed with the owner label", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      {:ok, card} = Cards.add_owner(card, :agent, {:user, user.id})

      assert [_created, %Schemas.Activity{type: :owners_changed, actor_type: :user, meta: meta}] =
               activities(card)

      assert meta == %{"action" => "added", "owner" => "AI"}
    end

    test "adding an existing owner logs nothing new", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.add_owner(card, {:user, user.id})

      {:ok, card} = Cards.add_owner(card, {:user, user.id})

      assert Enum.map(activities(card), & &1.type) == [:created, :owners_changed]
    end

    test "remove_owner/3 logs the user's name; a no-op remove logs nothing", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.add_owner(card, {:user, user.id})

      {:ok, card} = Cards.remove_owner(card, {:user, user.id})
      {:ok, card} = Cards.remove_owner(card, {:user, user.id})

      assert [_created, _added, %Schemas.Activity{type: :owners_changed, meta: meta}] = activities(card)
      assert meta == %{"action" => "removed", "owner" => "Ada Lovelace"}
    end

    test "set_owners/3 logs the new owner labels", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      {:ok, card} = Cards.set_owners(card, [:agent, {:user, user.id}], {:user, user.id})

      assert [_created, %Schemas.Activity{type: :owners_changed, meta: meta}] = activities(card)
      assert meta == %{"action" => "set", "owners" => ["AI", "Ada Lovelace"]}
    end
  end

  describe "owner preloading" do
    test "every card-returning function preloads owners", %{board: board, stage: stage} do
      {:ok, created} = Cards.create_card(stage, %{title: "Preloaded"})
      assert created.owners == []

      assert [%Card{owners: []}] = Cards.list_cards(board)
      assert %Card{owners: []} = Cards.get_card_by_ref(board, "RLY-1")

      {:ok, updated} = Cards.update_card(created, %{title: "Still preloaded"})
      assert updated.owners == []

      target = insert(:stage, board: board, position: 2)
      {:ok, moved} = Cards.move_card(created, target, 0)
      assert moved.owners == []
    end
  end

  defp stage_card_ids(board, stage) do
    board |> Cards.list_cards() |> Enum.filter(&(&1.stage_id == stage.id)) |> Enum.map(& &1.id)
  end

  defp stage_positions(board, stage) do
    board
    |> Cards.list_cards()
    |> Enum.filter(&(&1.stage_id == stage.id))
    |> Enum.map(& &1.position)
  end

  defp activities(card) do
    Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, order_by: a.id)
  end
end
