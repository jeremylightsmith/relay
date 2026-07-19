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

    test "inserts each new card at the top of its stage, shifting the rest down",
         %{board: board, stage: stage} do
      other_stage = insert(:stage, board: board, position: 2)

      {:ok, c1} = Cards.create_card(stage, %{title: "A"})
      {:ok, c2} = Cards.create_card(stage, %{title: "B"})
      {:ok, c3} = Cards.create_card(other_stage, %{title: "C"})

      # newest is first; each create re-indexes the stage to 1..n
      assert c2.position == 1
      assert Repo.get!(Card, c1.id).position == 2
      assert c3.position == 1
      assert c3.ref_number == 3

      titles =
        board
        |> Cards.list_cards()
        |> Enum.filter(&(&1.stage_id == stage.id))
        |> Enum.map(& &1.title)

      assert titles == ["B", "A"]
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

      # top-insert: a2 lands above a1 within stage; stage still orders before stage2
      assert Enum.map(Cards.list_cards(board), & &1.id) == [a2.id, a1.id, b1.id]
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

    test "excludes archived cards", %{board: board, stage: stage} do
      {:ok, keep} = Cards.create_card(stage, %{title: "Keep"})
      {:ok, hide} = Cards.create_card(stage, %{title: "Hide"})
      {:ok, _archived} = Cards.archive_card(hide)

      assert Enum.map(Cards.list_cards(board), & &1.id) == [keep.id]
    end

    test "omits description/acceptance_criteria/spec/plan but keeps every other field and the preloads",
         %{board: board, stage: stage} do
      card =
        insert(:card,
          stage: stage,
          description: "d",
          acceptance_criteria: "ac",
          spec: "s",
          plan: "p",
          status: :working
        )

      insert(:card_owner, card: card)
      insert(:sub_task, card: card, title: "todo")

      assert [loaded] = Cards.list_cards(board)

      assert loaded.description == nil
      assert loaded.acceptance_criteria == nil
      assert loaded.spec == nil
      assert loaded.plan == nil
      assert loaded.title == card.title
      assert loaded.status == :working
      assert [%Schemas.CardOwner{}] = loaded.owners
      assert [%Schemas.SubTask{title: "todo"}] = loaded.sub_tasks
    end

    test "preserves the rejection embed through the trim", %{board: board, stage: stage} do
      card = insert(:card, stage: stage)

      {:ok, _} =
        card
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:rejection, %Schemas.CardRejection{
          note: "fix it",
          from_stage_id: stage.id,
          from_stage_name: "Code",
          to_stage_id: stage.id,
          to_stage_name: "Plan",
          rejected_by: "Relay AI",
          rejected_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
        |> Repo.update()

      assert [loaded] = Cards.list_cards(board)
      assert %Schemas.CardRejection{note: "fix it"} = loaded.rejection
    end
  end

  describe "count_cards/1" do
    test "counts the board's non-archived cards, excluding archived and other boards",
         %{board: board, stage: stage} do
      insert(:card, stage: stage)
      insert(:card, stage: stage)
      archived = insert(:card, stage: stage)
      {:ok, _} = Cards.archive_card(archived)

      other = insert(:board)
      insert(:card, stage: insert(:stage, board: other))

      assert Cards.count_cards(board) == 2
    end
  end

  describe "list_cards/2 with :exclude_stage_ids" do
    test "omits cards in the excluded stages and keeps the rest", %{board: board, stage: stage} do
      other = insert(:stage, board: board, position: 2)
      keep = insert(:card, stage: stage)
      _drop = insert(:card, stage: other)

      ids = Enum.map(Cards.list_cards(board, exclude_stage_ids: [other.id]), & &1.id)
      assert ids == [keep.id]
    end

    test "an empty exclude list keeps every card", %{board: board, stage: stage} do
      insert(:card, stage: stage)
      assert length(Cards.list_cards(board, exclude_stage_ids: [])) == 1
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

    test "persists pr_url and it survives a reload", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Runner card"})

      assert {:ok, %Card{} = updated} =
               Cards.update_card(card, %{pr_url: "https://github.com/acme/relay/pull/42"})

      assert updated.pr_url == "https://github.com/acme/relay/pull/42"

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.pr_url == "https://github.com/acme/relay/pull/42"
    end

    test "setting pr_url never touches the programmatic fields", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Pinned"})

      assert {:ok, updated} =
               Cards.update_card(card, %{
                 pr_url: "https://github.com/acme/relay/pull/42",
                 board_id: card.board_id + 1,
                 stage_id: card.stage_id + 1,
                 position: 99,
                 ref_number: 99
               })

      assert updated.pr_url == "https://github.com/acme/relay/pull/42"
      assert updated.board_id == card.board_id
      assert updated.stage_id == card.stage_id
      assert updated.position == card.position
      assert updated.ref_number == card.ref_number
    end
  end

  describe "update_card/2 tag" do
    setup %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Tagged"})
      %{card: card}
    end

    test "sets, changes, and clears the tag", %{card: card} do
      assert {:ok, card} = Cards.update_card(card, %{tag: "infra"})
      assert card.tag == "infra"

      assert {:ok, card} = Cards.update_card(card, %{tag: "design"})
      assert card.tag == "design"

      assert {:ok, card} = Cards.update_card(card, %{tag: ""})
      assert card.tag == nil
    end

    test "nil clears the tag", %{card: card} do
      {:ok, card} = Cards.update_card(card, %{tag: "infra"})

      assert {:ok, card} = Cards.update_card(card, %{tag: nil})
      assert card.tag == nil
    end

    test "trims whitespace and strips a single leading #", %{card: card} do
      assert {:ok, card} = Cards.update_card(card, %{tag: " #infra "})
      assert card.tag == "infra"

      assert {:ok, card} = Cards.update_card(card, %{tag: "##meta"})
      assert card.tag == "#meta"
    end

    test "whitespace-only and bare-# values clear the tag", %{card: card} do
      {:ok, card} = Cards.update_card(card, %{tag: "infra"})

      assert {:ok, card} = Cards.update_card(card, %{tag: "#"})
      assert card.tag == nil

      {:ok, card} = Cards.update_card(card, %{tag: "infra"})

      assert {:ok, card} = Cards.update_card(card, %{tag: "   "})
      assert card.tag == nil
    end
  end

  describe "list_board_tags/1" do
    test "returns distinct non-nil tags sorted alphabetically", %{board: board, stage: stage} do
      {:ok, _} = Cards.create_card(stage, %{title: "A", tag: "infra"})
      {:ok, _} = Cards.create_card(stage, %{title: "B", tag: "design"})
      {:ok, _} = Cards.create_card(stage, %{title: "C", tag: "infra"})
      {:ok, _} = Cards.create_card(stage, %{title: "D"})

      assert Cards.list_board_tags(board.id) == ["design", "infra"]
    end

    test "excludes archived cards' tags", %{board: board, stage: stage} do
      {:ok, _keep} = Cards.create_card(stage, %{title: "Keep", tag: "design"})
      {:ok, gone} = Cards.create_card(stage, %{title: "Gone", tag: "legacy"})
      {:ok, _} = Cards.archive_card(gone)

      assert Cards.list_board_tags(board.id) == ["design"]
    end

    test "is scoped to the given board", %{board: board, stage: stage} do
      other_stage = insert(:stage)
      {:ok, _} = Cards.create_card(other_stage, %{title: "Elsewhere", tag: "other"})
      {:ok, _} = Cards.create_card(stage, %{title: "Here", tag: "mine"})

      assert Cards.list_board_tags(board.id) == ["mine"]
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

    test "still returns an archived card (loadable by ref, like archived boards)", %{
      board: board,
      stage: stage
    } do
      {:ok, card} = Cards.create_card(stage, %{title: "Archived but linkable"})
      {:ok, _archived} = Cards.archive_card(card)

      assert %Card{id: id, archived_at: at} = Cards.get_card_by_ref(board, "RLY-1")
      assert id == card.id
      assert at
    end
  end

  describe "get_card_light_by_ref/2" do
    test "loads light columns with heavy fields nil, owners and sub_tasks preloaded",
         %{board: board, stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Light me", tag: "perf"})

      {:ok, _} =
        Cards.update_card(card, %{
          description: "d",
          acceptance_criteria: "ac",
          spec: "s",
          plan: "p",
          ai_result: %{"summary" => "x"}
        })

      {:ok, _} = Cards.set_sub_tasks(card, [%{"title" => "One"}, %{"title" => "Two"}])

      light = Cards.get_card_light_by_ref(board, "RLY-1")

      assert light.id == card.id
      assert light.title == "Light me"
      assert light.tag == "perf"
      assert light.status == :ready
      # heavy fields are not selected
      assert light.description == nil
      assert light.acceptance_criteria == nil
      assert light.spec == nil
      assert light.plan == nil
      assert light.ai_result == nil
      # associations still preloaded
      assert is_list(light.owners)
      assert Enum.map(light.sub_tasks, & &1.title) == ["One", "Two"]
    end

    test "returns nil for an unknown ref number", %{board: board} do
      assert Cards.get_card_light_by_ref(board, "RLY-99") == nil
    end

    test "returns nil for malformed or foreign-key refs", %{board: board, stage: stage} do
      {:ok, _card} = Cards.create_card(stage, %{title: "Present"})

      for ref <- ["", "RLY-", "nope", "OPS-1"] do
        assert Cards.get_card_light_by_ref(board, ref) == nil, "expected nil for #{inspect(ref)}"
      end
    end

    test "never returns another board's card", %{board: board} do
      other_board = insert(:board, key: "OPS")
      other_stage = insert(:stage, board: other_board, position: 1)
      {:ok, _card} = Cards.create_card(other_stage, %{title: "Foreign"})

      # the RLY board has no card #1 yet
      assert Cards.get_card_light_by_ref(board, "RLY-1") == nil
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

      # top-insert order is [third, second, first]; move the bottom card to the top
      assert {:ok, moved} = Cards.move_card(first, stage, 0)

      assert moved.stage_id == stage.id
      assert stage_card_ids(board, stage) == [moved.id, third.id, second.id]
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

  describe "cross-stage move snaps status to the destination type's default (ADR 0003)" do
    setup %{board: board} do
      %{
        work_stage: insert(:stage, board: board, type: :work, position: 10),
        backlog_stage: insert(:stage, board: board, type: :queue, position: 11)
      }
    end

    test "an invalid status snaps to the destination type's default", %{work_stage: work, backlog_stage: backlog} do
      {:ok, card} = Cards.create_card(work, %{title: "x"})
      {:ok, card} = Cards.set_status(card, %{status: :working})

      assert {:ok, moved} = Cards.move_card(card, backlog, 0)
      assert moved.status == :ready
    end

    test "a status already valid for the destination survives the move", %{work_stage: work, backlog_stage: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "x"})

      assert {:ok, moved} = Cards.move_card(card, work, 0)
      assert moved.status == :ready
    end

    test "a :ready card entering a review stage becomes :in_review so it can be reviewed",
         %{board: board, backlog_stage: backlog} do
      review = insert(:stage, board: board, type: :review, position: 12)
      {:ok, card} = Cards.create_card(backlog, %{title: "x"})
      assert card.status == :ready

      assert {:ok, moved} = Cards.move_card(card, review, 0)
      assert moved.status == :in_review
    end

    test "needs_input -> queue clears blocked_since", %{work_stage: work, backlog_stage: backlog} do
      {:ok, card} = Cards.create_card(work, %{title: "blocked"})
      {:ok, card} = Cards.set_status(card, %{status: :needs_input})
      assert card.blocked_since

      {:ok, moved} = Cards.move_card(card, backlog, 0)
      assert moved.status == :ready
      assert is_nil(moved.blocked_since)
    end

    test "a same-stage reorder does not change status", %{work_stage: work} do
      {:ok, a} = Cards.create_card(work, %{title: "a"})
      {:ok, a} = Cards.set_status(a, %{status: :needs_input})
      {:ok, moved} = Cards.move_card(a, work, 0)
      assert moved.status == :needs_input
    end
  end

  describe "the claim rule on move (RLY-47)" do
    setup %{board: board} do
      %{
        ai_stage: insert(:stage, board: board, type: :planning, ai_enabled: true, position: 20),
        human_work: insert(:stage, board: board, type: :work, ai_enabled: false, position: 21),
        queue_stage: insert(:stage, board: board, type: :queue, ai_enabled: false, position: 22),
        done_stage: insert(:stage, board: board, type: :done, ai_enabled: false, position: 23),
        review_stage: insert(:stage, board: board, type: :review, ai_enabled: false, position: 24),
        user: insert(:user)
      }
    end

    test "an unowned card a HUMAN moves into an AI-enabled stage is claimed by that human (rule 3, corrected)",
         %{stage: stage, ai_stage: ai_stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "x"})

      assert {:ok, moved} = Cards.move_card(card, ai_stage, 0, {:user, user.id})
      assert [%{actor_type: :user, user_id: uid}] = moved.owners
      assert uid == user.id
    end

    test "an unowned card an AGENT moves into an AI-enabled stage is claimed by Relay AI (rule 1)",
         %{stage: stage, ai_stage: ai_stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "x"})

      assert {:ok, moved} = Cards.move_card(card, ai_stage, 0, :agent)
      assert [%{actor_type: :agent}] = moved.owners
    end

    test "an unowned card + a human move into a human-only work stage claims that human (rule 3)",
         %{stage: stage, human_work: human_work, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "x"})

      assert {:ok, moved} = Cards.move_card(card, human_work, 0, {:user, user.id})
      assert [%{actor_type: :user, user_id: uid}] = moved.owners
      assert uid == user.id
    end

    test "an agent move into a human-only work stage leaves the card unowned",
         %{stage: stage, human_work: human_work} do
      {:ok, card} = Cards.create_card(stage, %{title: "x"})

      assert {:ok, moved} = Cards.move_card(card, human_work, 0, :agent)
      assert moved.owners == []
    end

    test "moves into Queue, Done, or a Review gate never claim — not even a human into Review (rule 5)",
         %{stage: stage, queue_stage: queue_stage, done_stage: done_stage, review_stage: review_stage, user: user} do
      for target <- [queue_stage, done_stage, review_stage] do
        {:ok, card} = Cards.create_card(stage, %{title: "x"})
        assert {:ok, moved} = Cards.move_card(card, target, 0, {:user, user.id})
        assert moved.owners == [], "expected no claim moving into a #{target.type} stage"
      end
    end

    test "an already-owned card keeps its owners across moves — no hand-back (rules 5 & 6)",
         %{stage: stage, human_work: human_work, done_stage: done_stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "x"})
      {:ok, card} = Cards.assign_ai(card)

      # A human moving an AI-owned card does NOT claim it (already owned → untouched).
      assert {:ok, at_work} = Cards.move_card(card, human_work, 0, {:user, user.id})
      assert [%{actor_type: :agent}] = at_work.owners

      # Reaching a Done stage keeps Relay AI as the owner (provenance).
      assert {:ok, in_done} = Cards.move_card(at_work, done_stage, 0)
      assert [%{actor_type: :agent}] = in_done.owners
      assert in_done.status == :ready
    end
  end

  describe "set_status/3" do
    test "sets status and preloads owners", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:ok, %Card{} = updated} = Cards.set_status(card, %{"status" => "working"})

      assert updated.status == :working
      assert updated.owners == []
      assert Repo.get!(Card, card.id).status == :working
    end

    test "returns an error changeset and persists nothing on invalid status", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:error, %Ecto.Changeset{}} = Cards.set_status(card, %{"status" => "banana"})

      assert Repo.get!(Card, card.id).status == :ready
    end
  end

  describe "set_status_snapped/3" do
    test "a review-stage card set to :ready persists :in_review and logs the change", %{board: board} do
      review = insert(:stage, board: board, type: :review, position: 30)
      card = insert(:card, stage: review, status: :working)

      assert {:ok, %Card{} = updated} = Cards.set_status_snapped(card, %{"status" => "ready"})
      assert updated.status == :in_review
      assert Repo.get!(Card, card.id).status == :in_review

      assert %Schemas.Activity{type: :status_changed, meta: meta} =
               updated |> activities() |> Enum.find(&(&1.type == :status_changed))

      assert meta == %{"from_status" => "working", "to_status" => "in_review"}
    end

    test "a work-stage card set to :ready stays :ready (valid, not coerced)", %{board: board} do
      work = insert(:stage, board: board, type: :work, position: 31)
      card = insert(:card, stage: work, status: :working)

      assert {:ok, %Card{} = updated} = Cards.set_status_snapped(card, %{"status" => "ready"})
      assert updated.status == :ready
    end

    test "a queue-stage card set to :in_review coerces to :ready", %{board: board} do
      queue = insert(:stage, board: board, type: :queue, position: 32)
      card = insert(:card, stage: queue, status: :ready)

      assert {:ok, %Card{} = updated} = Cards.set_status_snapped(card, %{"status" => "in_review"})
      assert updated.status == :ready
    end

    test "a valid same-status re-set logs nothing (parity with set_status/3)", %{board: board} do
      work = insert(:stage, board: board, type: :work, position: 33)
      card = insert(:card, stage: work, status: :working)

      {:ok, card} = Cards.set_status_snapped(card, %{"status" => "working"})

      refute Enum.any?(activities(card), &(&1.type == :status_changed))
    end

    test "a non-enum status still returns an error changeset", %{board: board} do
      work = insert(:stage, board: board, type: :work, position: 34)
      card = insert(:card, stage: work, status: :working)

      assert {:error, %Ecto.Changeset{}} = Cards.set_status_snapped(card, %{"status" => "nope"})
    end
  end

  describe "mark_failed/3 (RLY-179)" do
    setup do
      board = insert(:board)
      stage = insert(:stage, board: board, type: :work)
      %{board: board, card: insert(:card, board: board, stage: stage)}
    end

    test "sets :failed, comments the detail, and logs a :failure activity carrying it", %{card: card} do
      detail = "The flow has nowhere to go after `final_fix` reported `failed`."

      assert {:ok, updated} = Cards.mark_failed(card, detail)
      assert updated.status == :failed

      timeline = Relay.Activity.list_timeline(updated)

      assert Enum.any?(timeline, &match?(%Schemas.Comment{kind: :comment, body: ^detail}, &1))
      refute Enum.any?(timeline, &match?(%Schemas.Comment{kind: :question}, &1))

      assert Enum.any?(
               timeline,
               &match?(%Schemas.Activity{type: :failure, meta: %{"detail" => ^detail}}, &1)
             )
    end

    # The board's log strip renders `entry.text` and falls back to the static phrase
    # "the agent stopped" when it is blank, so a text-less :failure row would erase the
    # failing node's output from the card face (RLY-179 review).
    test "logs the detail as the entry's text, so the board strip shows it", %{card: card} do
      detail = "The flow has nowhere to go after `final_fix` reported `failed`."

      assert {:ok, updated} = Cards.mark_failed(card, detail)

      assert %Schemas.Activity{text: ^detail} =
               [updated.id] |> Relay.Activity.newest_per_card() |> Map.fetch!(updated.id)
    end

    test "does not stamp blocked_since — a failed card is not waiting on an answer", %{card: card} do
      assert {:ok, updated} = Cards.mark_failed(card, "it died")
      assert is_nil(updated.blocked_since)
    end

    test "entering :failed from :needs_input clears blocked_since", %{card: card} do
      {:ok, blocked} = Cards.request_input(card, "which one?")
      assert blocked.blocked_since

      assert {:ok, updated} = Cards.mark_failed(blocked, "it died")
      assert updated.status == :failed
      assert is_nil(updated.blocked_since)
    end

    test "a failed card still counts as needing you", %{board: board, card: card} do
      {:ok, updated} = Cards.mark_failed(card, "it died")
      assert Cards.needs_you?(updated, Relay.Boards.list_stages(board))
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

    test "add_owner/3 is idempotent per actor", %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, updated} = Cards.add_owner(card, {:user, user.id})
      assert length(updated.owners) == 1

      {:ok, _card} = Cards.add_owner(card, :agent)
      {:ok, again} = Cards.add_owner(card, :agent)
      # exclusivity: assigning AI cleared the human, so AI is the sole owner
      assert [%{actor_type: :agent}] = again.owners
    end

    test "add_owner/3 returns an error changeset for an unknown user id", %{card: card} do
      assert {:error, %Ecto.Changeset{}} = Cards.add_owner(card, {:user, -1})
      assert {:ok, %Card{owners: []}} = Cards.set_owners(card, [])
    end

    test "remove_owner/3 removes only the matching actor and is idempotent",
         %{card: card, user: user} do
      other = insert(:user)
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, _card} = Cards.add_owner(card, {:user, other.id})

      assert {:ok, %Card{} = updated} = Cards.remove_owner(card, {:user, other.id})
      assert [%{actor_type: :user, user_id: uid}] = updated.owners
      assert uid == user.id

      assert {:ok, %Card{} = again} = Cards.remove_owner(card, {:user, other.id})
      assert [%{user_id: ^uid}] = again.owners

      assert {:ok, %Card{owners: []}} = Cards.remove_owner(card, {:user, user.id})
    end

    test "add_owner/3 with :agent clears human owners (AI exclusivity, rule 2)",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      assert {:ok, updated} = Cards.add_owner(card, :agent)
      assert [%{actor_type: :agent}] = updated.owners
    end

    test "add_owner/3 with a human on an AI-owned card removes the agent (take-over, rule 2)",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      assert {:ok, updated} = Cards.add_owner(card, {:user, user.id})
      assert [%{actor_type: :user, user_id: uid}] = updated.owners
      assert uid == user.id
    end

    test "assign_ai/2 makes Relay AI the sole owner and logs :owners_changed",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      assert {:ok, updated} = Cards.assign_ai(card)
      assert [%{actor_type: :agent}] = updated.owners
      assert Enum.any?(activities(card), &(&1.type == :owners_changed))
    end

    test "take_over/2 makes the user the sole owner and logs :owners_changed",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      assert {:ok, updated} = Cards.take_over(card, {:user, user.id})
      assert [%{actor_type: :user, user_id: uid}] = updated.owners
      assert uid == user.id
      assert Enum.any?(activities(card), &(&1.type == :owners_changed))
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

    test "returns :ai for an AI-owned card", %{card: card} do
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

      # A :ready card entering a review lane now snaps to :in_review (RLY-57 precondition), so a
      # :status_changed is logged alongside the :moved entry.
      assert moved.status == :in_review

      assert [%Schemas.Activity{type: :moved, meta: meta}] =
               Enum.filter(activities(moved), &(&1.type == :moved))

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

      assert meta == %{"from_status" => "ready", "to_status" => "in_review"}
    end

    test "a same-status re-set does not log", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.set_status(card, %{"status" => "working"})

      {:ok, card} = Cards.set_status(card, %{"status" => "working"})

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

  describe "archive_card/2 and unarchive_card/2" do
    test "archive stamps archived_at and preserves stage/position/owners", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Retire me"})
      {:ok, _owner} = Cards.add_owner(card, :agent)
      card = Cards.get_card_by_ref(Repo.get!(Board, stage.board_id), "RLY-1")

      assert {:ok, archived} = Cards.archive_card(card)

      assert archived.archived_at
      assert Card.archived?(archived)
      assert archived.stage_id == card.stage_id
      assert archived.position == card.position
      assert Enum.map(archived.owners, & &1.actor_type) == [:agent]
    end

    test "archive logs :archived attributed to the actor", %{stage: stage} do
      user = insert(:user, name: "Ada Lovelace")
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      {:ok, archived} = Cards.archive_card(card, {:user, user.id})

      assert [_created, %Schemas.Activity{type: :archived, actor_type: :user, user_id: uid, meta: %{}}] =
               activities(archived)

      assert uid == user.id
    end

    test "archiving an already-archived card re-stamps but does not log twice", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, once} = Cards.archive_card(card)

      {:ok, twice} = Cards.archive_card(once)

      assert twice.archived_at
      assert Enum.count(activities(twice), &(&1.type == :archived)) == 1
    end

    test "archive broadcasts {:card_archived, card}", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      Relay.Events.subscribe(card.board_id)

      assert {:ok, _} = Cards.archive_card(card)
      assert_receive {:card_archived, %Card{id: id, archived_at: at}}
      assert id == card.id
      assert at
    end

    test "unarchive clears archived_at and logs :unarchived", %{stage: stage} do
      user = insert(:user, name: "Ada Lovelace")
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, archived} = Cards.archive_card(card)

      assert {:ok, restored} = Cards.unarchive_card(archived, {:user, user.id})

      assert restored.archived_at == nil
      refute Card.archived?(restored)

      assert [_created, _archived, %Schemas.Activity{type: :unarchived, actor_type: :user}] =
               activities(restored)
    end

    test "unarchive broadcasts {:card_upserted, card} (reuses the upsert event)", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, archived} = Cards.archive_card(card)
      Relay.Events.subscribe(card.board_id)

      assert {:ok, _} = Cards.unarchive_card(archived)
      assert_receive {:card_upserted, %Card{archived_at: nil}}
    end

    test "unarchiving an active card is a no-op that logs nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:ok, same} = Cards.unarchive_card(card)

      assert same.archived_at == nil
      assert Enum.map(activities(same), & &1.type) == [:created]
    end
  end

  describe "list_archived_cards/1" do
    test "returns only archived cards, most-recently-archived first, with stage + owners", %{
      board: board,
      stage: stage
    } do
      {:ok, active} = Cards.create_card(stage, %{title: "Active"})
      {:ok, first} = Cards.create_card(stage, %{title: "First archived"})
      {:ok, second} = Cards.create_card(stage, %{title: "Second archived"})
      {:ok, _first} = Cards.archive_card(first)
      {:ok, _second} = Cards.archive_card(second)

      # archived_at is truncated to the second, so both archives tie; the
      # `desc: id` tiebreak in list_archived_cards/1 puts the later-created
      # (higher-id) "Second archived" first — deterministic without sleeping.
      archived = Cards.list_archived_cards(board)

      assert Enum.map(archived, & &1.title) == ["Second archived", "First archived"]
      refute active.id in Enum.map(archived, & &1.id)
      assert %Schemas.Stage{} = hd(archived).stage
      assert is_list(hd(archived).owners)
    end

    test "returns [] when nothing is archived", %{board: board, stage: stage} do
      {:ok, _active} = Cards.create_card(stage, %{title: "Active"})
      assert Cards.list_archived_cards(board) == []
    end
  end

  describe "count_archived_cards/1" do
    test "counts only archived cards on the board", %{board: board, stage: stage} do
      {:ok, _active} = Cards.create_card(stage, %{title: "Active"})
      {:ok, a} = Cards.create_card(stage, %{title: "A"})
      {:ok, b} = Cards.create_card(stage, %{title: "B"})
      {:ok, _a} = Cards.archive_card(a)
      {:ok, _b} = Cards.archive_card(b)

      assert Cards.count_archived_cards(board) == 2
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
