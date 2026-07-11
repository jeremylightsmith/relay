defmodule Relay.CardsSendBackTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Card

  # Positions 1-5: Spec (queue) | Plan (planning) | Code (work) | Review (review, previous main =
  # Code) | Done (done, last).
  setup do
    board = insert(:board, key: "RLY")
    spec = insert(:stage, board: board, name: "Spec", type: :queue, category: :unstarted, position: 1)
    plan = insert(:stage, board: board, name: "Plan", type: :planning, ai_enabled: true, category: :planning, position: 2)
    code = insert(:stage, board: board, name: "Code", type: :work, ai_enabled: true, category: :in_progress, position: 3)

    review =
      insert(:stage,
        board: board,
        name: "Review",
        type: :review,
        category: :in_progress,
        position: 4
      )

    done =
      insert(:stage,
        board: board,
        name: "Done",
        type: :done,
        category: :complete,
        position: 5
      )

    %{board: board, spec: spec, plan: plan, code: code, review: review, done: done}
  end

  describe "send_back/4" do
    test "moves back, sets arrival status, posts the note, logs :rejected, sets the embed",
         %{review: review, spec: spec} do
      card = insert(:card, stage: review)

      assert {:ok, %Card{} = sent} = Cards.send_back(card, spec, "This is really a spec problem", :agent)
      assert sent.stage_id == spec.id
      assert sent.status == :ready

      assert %Schemas.CardRejection{} = rejection = sent.rejection
      assert rejection.note == "This is really a spec problem"
      assert rejection.from_stage_id == review.id
      assert rejection.from_stage_name == "Review"
      assert rejection.to_stage_id == spec.id
      assert rejection.to_stage_name == "Spec"
      assert rejection.rejected_by == "Relay AI"
      assert rejection.rejected_at

      timeline = Activity.list_timeline(card)
      assert Enum.any?(timeline, &(is_struct(&1, Schemas.Comment) and &1.body == "This is really a spec problem"))
      entry = Enum.find(timeline, &(Map.get(&1, :type) == :rejected))
      assert entry.meta == %{"from_stage" => "Review", "to_stage" => "Spec", "note" => "This is really a spec problem"}
    end

    test "accepts a stage id as the target", %{review: review, code: code} do
      card = insert(:card, stage: review)
      assert {:ok, sent} = Cards.send_back(card, code.id, "back to code", :agent)
      assert sent.stage_id == code.id
    end

    test "blank note → {:error, :missing_note}", %{review: review, spec: spec} do
      card = insert(:card, stage: review)
      assert {:error, :missing_note} = Cards.send_back(card, spec, "   ", :agent)
      assert Repo.get!(Card, card.id).rejection == nil
    end

    test "a forward target → {:error, :invalid_target}", %{code: code, review: review} do
      card = insert(:card, stage: code)
      assert {:error, :invalid_target} = Cards.send_back(card, review, "nope", :agent)
    end

    test "a sub-lane (non-main) target → {:error, :invalid_target}", %{review: review, code: code} do
      {:ok, sublane} = Boards.enable_lane(code, :review)
      card = insert(:card, stage: review)
      assert {:error, :invalid_target} = Cards.send_back(card, sublane, "nope", :agent)
    end

    test "a fresh send-back replaces the existing open rejection", %{review: review, spec: spec, plan: plan} do
      card = insert(:card, stage: review)
      {:ok, once} = Cards.send_back(card, spec, "first", :agent)
      assert once.rejection.to_stage_id == spec.id

      # climb forward one stage (still before Review, so it stays live), then re-reject.
      {:ok, climbed} = Cards.move_card(once, plan, 0, :agent)
      assert climbed.rejection

      {:ok, twice} = Cards.send_back(climbed, spec, "second", :agent)
      assert twice.rejection.note == "second"
      # still exactly one embed (single open rejection).
      assert Repo.get!(Card, card.id).rejection.note == "second"
    end
  end

  describe "clearing (addressed)" do
    test "clears when a forward move reaches the from-stage", %{review: review, spec: spec, plan: plan, code: code} do
      card = insert(:card, stage: review)
      {:ok, sent} = Cards.send_back(card, spec, "redo from spec", :agent)
      assert sent.rejection.from_stage_id == review.id

      {:ok, at_plan} = Cards.move_card(sent, plan, 0, :agent)
      assert at_plan.rejection, "survives an intermediate stage of the redo"

      {:ok, at_code} = Cards.move_card(at_plan, code, 0, :agent)
      assert at_code.rejection, "still open before reaching the from-stage"

      {:ok, at_review} = Cards.move_card(at_code, review, 0, :agent)
      assert at_review.rejection == nil, "climbing back to the from-stage clears it"
    end

    test "clears on approve even before reaching the from-stage", %{review: review, done: done, code: code} do
      # Rejected from the last gate (Done) all the way back to Code.
      card = insert(:card, stage: done)
      {:ok, sent} = Cards.send_back(card, code, "fix it", :agent)
      assert sent.rejection.from_stage_id == done.id

      # Climb to the Review gate (still before Done → move alone won't clear).
      {:ok, at_review} = Cards.move_card(sent, review, 0, :agent)
      assert at_review.rejection, "survives — hasn't reached Done yet"

      # Approve past Review → acceptance clears it.
      {:ok, approved} = Cards.approve(at_review, :agent)
      assert approved.rejection == nil
    end

    test "clears on mark_done", %{review: review, code: code} do
      card = insert(:card, stage: review)
      {:ok, sent} = Cards.send_back(card, code, "fix it", :agent)
      {:ok, done} = Cards.mark_done(sent, :agent)
      assert done.status == :ready
      assert done.rejection == nil
    end
  end

  describe "reject/4 (review-position wrapper)" do
    test "defaults the target to the previous main stage", %{review: review, code: code} do
      card = insert(:card, stage: review)
      assert {:ok, rejected} = Cards.reject(card, "missing edge cases", :agent)
      assert rejected.stage_id == code.id
      assert rejected.rejection.to_stage_id == code.id
    end

    test "honors an explicit :to override", %{review: review, spec: spec} do
      card = insert(:card, stage: review)
      assert {:ok, rejected} = Cards.reject(card, "spec problem", :agent, to: spec)
      assert rejected.stage_id == spec.id
    end

    test "returns {:error, :not_in_review} on a non-review stage without a target", %{code: code} do
      card = insert(:card, stage: code)
      assert {:error, :not_in_review} = Cards.reject(card, "nope", :agent)
    end
  end
end
