defmodule Relay.CardsTransitionStageIdsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Activity

  # Next up (queue) | Spec (planning) + Spec · Review | Done (review — terminal, so an approve
  # there completes in place).
  setup do
    board = insert(:board)
    next_up = insert(:stage, board: board, name: "Next up", type: :queue, category: :unstarted, position: 1)
    spec = insert(:stage, board: board, name: "Spec", type: :planning, category: :planning, position: 2)
    done = insert(:stage, board: board, name: "Done", type: :review, category: :complete, position: 3)
    {:ok, spec_review} = Boards.enable_lane(spec, :review)

    %{next_up: next_up, spec: spec, spec_review: spec_review, done: done}
  end

  test "a cross-stage move records both stage ids beside the names", %{next_up: next_up, spec: spec} do
    card = insert(:card, stage: next_up, status: :ready)

    {:ok, _moved} = Cards.move_card(card, spec, 0)

    meta = last_meta(card, :moved)
    assert meta["from_stage_id"] == next_up.id
    assert meta["to_stage_id"] == spec.id
    assert meta["from_stage"] == "Next up"
    assert meta["to_stage"] == "Spec"
  end

  test "a moving approve records the review stage and its destination",
       %{spec_review: spec_review, done: done} do
    card = insert(:card, stage: spec_review, status: :in_review)

    {:ok, _approved} = Cards.approve(card)

    meta = last_meta(card, :approved)
    assert meta["from_stage_id"] == spec_review.id
    assert meta["to_stage_id"] == done.id
    assert meta["from_stage"] == "Spec · Review"
  end

  test "an in-place approve at the terminal stage records the same id on both sides", %{done: done} do
    card = insert(:card, stage: done, status: :in_review)

    {:ok, _approved} = Cards.approve(card)

    meta = last_meta(card, :approved)
    assert meta["from_stage_id"] == done.id
    assert meta["to_stage_id"] == done.id
  end

  test "a reject records ids on both the :moved and the :rejected rows",
       %{spec: spec, spec_review: spec_review} do
    card = insert(:card, stage: spec_review, status: :in_review)

    {:ok, _rejected} = Cards.reject(card, "needs work")

    moved = last_meta(card, :moved)
    assert moved["from_stage_id"] == spec_review.id
    assert moved["to_stage_id"] == spec.id

    rejected = last_meta(card, :rejected)
    assert rejected["from_stage_id"] == spec.id
    assert rejected["to_stage_id"] == spec.id
  end

  defp last_meta(card, type) do
    Repo.one!(
      from a in Activity,
        where: a.card_id == ^card.id and a.type == ^type,
        order_by: [desc: a.id],
        limit: 1,
        select: a.meta
    )
  end
end
