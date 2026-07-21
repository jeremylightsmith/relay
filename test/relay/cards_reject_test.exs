defmodule Relay.CardsRejectTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Card

  # Spec(queue,1) | Plan(planning,2) | Code(work,3) | Review(review,4) | Done(done,5).
  setup do
    board = insert(:board, key: "RLY")
    spec = insert(:stage, board: board, name: "Spec", type: :queue, category: :unstarted, position: 1)
    plan = insert(:stage, board: board, name: "Plan", type: :planning, ai_enabled: true, category: :planning, position: 2)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, category: :in_progress, position: 3)
    review = insert(:stage, board: board, name: "Review", type: :review, category: :in_progress, position: 4)
    done = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 5)

    %{board: board, spec: spec, plan: plan, code: code, review: review, done: done}
  end

  describe "reject/3 routing" do
    test "a top-level review with no reject_to routes to the previous main stage, note+embed+log",
         %{review: review, code: code} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, %Card{} = rejected} = Cards.reject(card, "Handle the empty case", :agent)
      assert rejected.stage_id == code.id
      assert rejected.status == :ready

      assert %Schemas.CardRejection{} = r = rejected.rejection
      assert r.note == "Handle the empty case"
      assert r.from_stage_id == review.id
      assert r.from_stage_name == "Review"
      assert r.to_stage_id == code.id
      assert r.to_stage_name == "Code"
      assert r.rejected_by == "Relay AI"
      assert r.rejected_at

      timeline = Activity.list_timeline(card)
      assert Enum.any?(timeline, &(is_struct(&1, Schemas.Comment) and &1.body == "Handle the empty case"))
      entry = Enum.find(timeline, &(Map.get(&1, :type) == :rejected))
      assert entry.meta == %{"from_stage" => "Review", "to_stage" => "Code", "note" => "Handle the empty case"}
    end

    test "a top-level review honors its configured reject_to over the previous stage",
         %{review: review, plan: plan} do
      {:ok, review} = Boards.update_stage(review, %{reject_to_stage_id: plan.id})
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, rejected} = Cards.reject(card, "re-plan this", :agent)
      assert rejected.stage_id == plan.id
      assert rejected.status == :ready
      assert rejected.rejection.to_stage_id == plan.id
    end

    test "a review sub-lane routes back to its own parent main stage",
         %{plan: plan} do
      {:ok, sublane} = Boards.enable_lane(plan, :review)
      card = insert(:card, stage: sublane)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, rejected} = Cards.reject(card, "spec is wrong", :agent)
      assert rejected.stage_id == plan.id
      assert rejected.status == :ready
      assert rejected.rejection.from_stage_id == plan.id
      assert rejected.rejection.to_stage_id == plan.id
    end

    test "a reject onto a review-type destination is left snapped, not forced :ready",
         %{board: board, review: review} do
      # A second review-type stage used as review's reject_to target.
      review2 =
        insert(:stage, board: board, name: "Re-review", type: :review, category: :in_progress, position: 6)

      {:ok, review} = Boards.update_stage(review, %{reject_to_stage_id: review2.id})
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      assert {:ok, rejected} = Cards.reject(card, "look again", :agent)
      assert rejected.stage_id == review2.id
      # :ready is invalid for a :review stage, so the move's snap (:in_review) stands.
      assert rejected.status == :in_review
    end

    test "reject_target/1 exposes the derived destination without moving the card",
         %{review: review, code: code} do
      card = insert(:card, stage: review)
      assert %Schemas.Stage{id: id} = Cards.reject_target(card)
      assert id == code.id
      # unchanged
      assert Repo.get!(Card, card.id).stage_id == review.id
    end

    test "tags its note comment with kind :changes_requested", %{review: review, code: code} do
      card = insert(:card, stage: review)
      {:ok, card} = Cards.set_status(card, %{status: :in_review})

      {:ok, rejected} = Cards.reject(card, "Please fix the copy", :agent)
      assert rejected.stage_id == code.id

      assert Enum.any?(
               Activity.list_conversation(rejected),
               &(&1.kind == :changes_requested and &1.body == "Please fix the copy")
             )
    end

    test "a blank note is rejected before anything moves", %{review: review} do
      card = insert(:card, stage: review)
      assert {:error, :missing_note} = Cards.reject(card, "   ", :agent)
      reloaded = Repo.get!(Card, card.id)
      assert reloaded.stage_id == review.id
      assert reloaded.rejection == nil
    end

    test "a non-review stage → {:error, :not_in_review}", %{code: code} do
      card = insert(:card, stage: code)
      assert {:error, :not_in_review} = Cards.reject(card, "nope", :agent)
      assert Cards.reject_target(card) == nil
    end

    test "a first-column top-level review with no target → {:error, :invalid_target}" do
      board = insert(:board, key: "RLY")
      first = insert(:stage, board: board, name: "Review", type: :review, category: :unstarted, position: 1)
      card = insert(:card, stage: first)

      assert Cards.reject_target(card) == nil
      assert {:error, :invalid_target} = Cards.reject(card, "nowhere to go", :agent)
    end
  end

  describe "rejection clearing (unchanged behavior, re-seeded via reject/3)" do
    test "a forward move that reaches the from-stage clears the rejection",
         %{review: review, plan: plan, code: code} do
      card = insert(:card, stage: review)
      {:ok, sent} = Cards.reject(card, "redo from code", :agent)
      assert sent.stage_id == code.id
      assert sent.rejection.from_stage_id == review.id

      {:ok, at_plan} = Cards.move_card(sent, plan, 0, :agent)
      assert at_plan.rejection, "survives an intermediate stage of the redo"

      {:ok, at_review} = Cards.move_card(at_plan, review, 0, :agent)
      assert at_review.rejection == nil, "climbing back to the from-stage clears it"
    end

    test "approve clears the rejection even before the card climbs back to the from-stage" do
      # Two gates so the from-stage (GateB) sits after an earlier gate (GateA).
      board = insert(:board, key: "RLY")
      insert(:stage, board: board, name: "Spec", type: :queue, category: :unstarted, position: 1)
      gate_a = insert(:stage, board: board, name: "GateA", type: :review, category: :unstarted, position: 2)
      code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 3)
      gate_b = insert(:stage, board: board, name: "GateB", type: :review, category: :in_progress, position: 4)
      insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 5)

      card = insert(:card, stage: gate_b)
      {:ok, sent} = Cards.reject(card, "fix it", :agent)
      assert sent.stage_id == code.id
      assert sent.rejection.from_stage_id == gate_b.id

      # Move back to the earlier gate (still before GateB → move alone won't clear).
      {:ok, at_gate_a} = Cards.move_card(sent, gate_a, 0, :agent)
      assert at_gate_a.rejection, "survives — hasn't reached GateB yet"

      {:ok, approved} = Cards.approve(at_gate_a, :agent)
      assert approved.stage_id == code.id
      assert approved.rejection == nil
    end

    test "mark_done clears the rejection", %{review: review, code: code} do
      card = insert(:card, stage: review)
      {:ok, sent} = Cards.reject(card, "fix it", :agent)
      assert sent.stage_id == code.id

      {:ok, done} = Cards.mark_done(sent, :agent)
      assert done.status == :ready
      assert done.rejection == nil
    end
  end
end
