defmodule Relay.CardsGatesTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Card

  # Pipeline (positions 1-5): Plan (work) | Code (work) | Review (review) | Deploy (work) |
  # Done (review, last — the final gate; approving with no next main stage completes in place).
  setup do
    board = insert(:board, key: "RLY")
    plan = insert(:stage, board: board, name: "Plan", type: :planning, ai_enabled: true, category: :planning, position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, category: :in_progress, position: 2)

    review =
      insert(:stage,
        board: board,
        name: "Review",
        type: :review,
        ai_enabled: false,
        category: :in_progress,
        position: 3
      )

    deploy =
      insert(:stage, board: board, name: "Deploy", type: :work, ai_enabled: true, category: :in_progress, position: 4)

    done =
      insert(:stage,
        board: board,
        name: "Done",
        type: :review,
        ai_enabled: false,
        category: :complete,
        position: 5
      )

    %{board: board, plan: plan, code: code, review: review, deploy: deploy, done: done}
  end

  describe "approve/2" do
    test "advances to the next main stage, arriving :working for a work-type target",
         %{review: review, deploy: deploy} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, %Card{} = approved} = Cards.approve(card, :agent)
      assert approved.stage_id == deploy.id
      assert approved.status == :working
    end

    test "arrives :ready when the next main stage is queue-type" do
      board = insert(:board)

      gate =
        insert(:stage,
          board: board,
          name: "Code",
          type: :review,
          category: :in_progress,
          position: 1
        )

      verify = insert(:stage, board: board, name: "Verify", type: :queue, category: :in_progress, position: 2)
      card = insert(:card, stage: gate)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == verify.id
      assert approved.status == :ready
    end

    test "skips sub-lane stages when finding the next stage", %{review: review, deploy: deploy} do
      {:ok, _sublane} = Boards.enable_lane(review, :review)
      {:ok, _sublane} = Boards.enable_lane(deploy, :done)
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == deploy.id
    end

    test "from a review substage whose parent has no Done substage, next = first main stage after parent",
         %{review: review, deploy: deploy} do
      {:ok, sublane} = Boards.enable_lane(review, :review)
      card = insert(:card, stage: sublane)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == deploy.id
      assert approved.status == :working
    end

    test "at the last main stage sets :ready in place (derives Done)", %{board: board, done: done} do
      card = insert(:card, stage: done)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == done.id
      assert approved.status == :ready
      assert Cards.done?(approved, Boards.list_stages(board))
    end

    test "logs an :approved activity with from/to stage names", %{review: review} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})
      {:ok, _approved} = Cards.approve(card, :agent)

      entry = card |> Activity.list_timeline() |> Enum.find(&(Map.get(&1, :type) == :approved))
      assert entry.actor_type == :agent
      assert entry.meta == %{"from_stage" => "Review", "to_stage" => "Deploy"}
    end

    test "broadcasts the move and the :approved timeline entry", %{board: board, review: review} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})
      card_id = card.id
      review_id = review.id
      :ok = Events.subscribe(board.id)

      {:ok, _approved} = Cards.approve(card)

      assert_receive {:card_moved, %Card{id: ^card_id}, ^review_id}
      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{type: :approved}}
    end

    test "never touches the card's owners", %{review: review} do
      card = insert(:card, stage: review)
      insert(:card_owner, card: card)

      {:ok, approved} = Cards.approve(card)
      assert [%{actor_type: :agent}] = approved.owners
    end

    test "returns {:error, :not_in_review} on a non-review stage", %{code: code} do
      card = insert(:card, stage: code)
      assert {:error, :not_in_review} = Cards.approve(card)
    end
  end

  describe "approve/2 into a Done substage (RLY-76)" do
    test "a card in a review substage lands in the parent's Done substage, parked :ready",
         %{board: board, code: code} do
      {:ok, review_sub} = Boards.enable_lane(code, :review)
      {:ok, done_sub} = Boards.enable_lane(code, :done)
      card = insert(:card, stage: review_sub)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == done_sub.id
      assert approved.status == :ready
      refute Cards.done?(approved, Boards.list_stages(board))
    end

    test "approve_target/1 returns the parent's Done substage for a review substage card",
         %{code: code} do
      {:ok, review_sub} = Boards.enable_lane(code, :review)
      {:ok, done_sub} = Boards.enable_lane(code, :done)
      card = insert(:card, stage: review_sub)

      assert %Schemas.Stage{id: id} = Cards.approve_target(card)
      assert id == done_sub.id
    end

    test "approve_target/1 returns the next main stage for a top-level review card",
         %{review: review, deploy: deploy} do
      card = insert(:card, stage: review)
      assert %Schemas.Stage{id: id} = Cards.approve_target(card)
      assert id == deploy.id
    end

    test "approve_target/1 is nil at the terminal review stage", %{done: done} do
      card = insert(:card, stage: done)
      assert Cards.approve_target(card) == nil
    end

    test "approve_target/1 is nil for a non-review stage", %{code: code} do
      card = insert(:card, stage: code)
      assert Cards.approve_target(card) == nil
    end
  end

  describe "reject/3" do
    test "routes to the previous main stage with :ready status, note comment, and :rejected entry",
         %{review: review, code: code} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, rejected} = Cards.reject(card, "Specs are missing edge cases", :agent)
      assert rejected.stage_id == code.id
      assert rejected.status == :ready

      timeline = Activity.list_timeline(card)
      assert Enum.any?(timeline, &(is_struct(&1, Schemas.Comment) and &1.body == "Specs are missing edge cases"))

      entry = Enum.find(timeline, &(Map.get(&1, :type) == :rejected))
      assert entry.actor_type == :agent

      assert entry.meta == %{
               "from_stage" => "Review",
               "to_stage" => "Code",
               "note" => "Specs are missing edge cases"
             }
    end

    test "a sub-lane card routes back to its own parent main stage", %{review: review} do
      {:ok, sublane} = Boards.enable_lane(review, :review)
      card = insert(:card, stage: sublane)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, rejected} = Cards.reject(card, "Please tighten the copy")
      assert rejected.stage_id == review.id
      assert rejected.status == :in_review
    end

    test "defaults to the previous main stage for a main-lane card", %{review: review, code: code} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, rejected} = Cards.reject(card, "Not ready")
      assert rejected.stage_id == code.id
    end

    test "returns {:error, :invalid_target} when the review stage has no earlier main stage" do
      board = insert(:board)
      review = insert(:stage, board: board, name: "Review", type: :review, category: :in_progress, position: 1)
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:error, :invalid_target} = Cards.reject(card, "nope")
    end

    test "never touches the card's owners", %{review: review} do
      card = insert(:card, stage: review)
      insert(:card_owner, card: card)

      {:ok, rejected} = Cards.reject(card, "Redo", :agent)
      assert [%{actor_type: :agent}] = rejected.owners
    end

    test "returns {:error, :not_in_review} on a non-review stage", %{code: code} do
      card = insert(:card, stage: code)
      assert {:error, :not_in_review} = Cards.reject(card, "nope")
    end

    test "requires a note", %{review: review} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})
      assert {:error, :missing_note} = Cards.reject(card, "   ")
    end
  end
end
