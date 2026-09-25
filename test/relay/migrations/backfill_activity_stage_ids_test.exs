# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.BackfillActivityStageIds) do
  "priv/repo/migrations/*_backfill_activity_stage_ids.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.BackfillActivityStageIdsTest do
  # The backfill sweeps the whole activities table, so keep it off the async pool.
  use Relay.DataCase, async: false

  alias Relay.Boards
  alias Relay.Repo.Migrations.BackfillActivityStageIds, as: Migration
  alias Schemas.Activity

  setup do
    board = insert(:board)
    spec = insert(:stage, board: board, name: "Spec", type: :planning, category: :planning, position: 1)
    code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 2)
    {:ok, spec_review} = Boards.enable_lane(spec, :review)
    card = insert(:card, stage: code)

    %{board: board, spec: spec, spec_review: spec_review, code: code, card: card}
  end

  test "main-stage and substage display names resolve to the card board's stage ids", ctx do
    moved = row(ctx.card, :moved, "Spec · Review", "Code")
    approved = row(ctx.card, :approved, "Spec", "Spec · Review")
    other = insert(:activity, card: ctx.card, type: :status_changed, meta: %{"from_status" => "ready"})

    assert Migration.backfill(Repo) == {2, 0}

    assert %{"from_stage_id" => from, "to_stage_id" => to} = Repo.get!(Activity, moved.id).meta
    assert {from, to} == {ctx.spec_review.id, ctx.code.id}

    assert %{"from_stage_id" => from, "to_stage_id" => to} = Repo.get!(Activity, approved.id).meta
    assert {from, to} == {ctx.spec.id, ctx.spec_review.id}

    assert Repo.get!(Activity, other.id).meta == %{"from_status" => "ready"}
  end

  test "a row naming a stage that no longer exists (renamed) is deleted", ctx do
    renamed = row(ctx.card, :moved, "Old spec", "Code")

    assert Migration.backfill(Repo) == {0, 1}
    assert Repo.get(Activity, renamed.id) == nil
  end

  test "an ambiguous name (two stages display the same) is deleted", ctx do
    insert(:stage, board: ctx.board, name: "Code", type: :work, category: :in_progress, position: 4)
    ambiguous = row(ctx.card, :rejected, "Spec", "Code")

    assert Migration.backfill(Repo) == {0, 1}
    assert Repo.get(Activity, ambiguous.id) == nil
  end

  test "names resolve against the card's own board only", ctx do
    other_board = insert(:board)
    insert(:stage, board: other_board, name: "Spec", type: :planning, category: :planning, position: 1)
    insert(:stage, board: other_board, name: "Code", type: :work, category: :in_progress, position: 2)
    moved = row(ctx.card, :moved, "Spec", "Code")

    assert Migration.backfill(Repo) == {1, 0}
    assert %{"from_stage_id" => from} = Repo.get!(Activity, moved.id).meta
    assert from == ctx.spec.id
  end

  test "a row that already carries ids is left alone (the backfill is idempotent)", ctx do
    meta = %{"from_stage" => "Gone", "to_stage" => "Gone", "from_stage_id" => 1, "to_stage_id" => 2}
    kept = insert(:activity, card: ctx.card, type: :moved, meta: meta)

    assert Migration.backfill(Repo) == {0, 0}
    assert Repo.get!(Activity, kept.id).meta == meta
  end

  defp row(card, type, from, to) do
    insert(:activity, card: card, type: type, meta: %{"from_stage" => from, "to_stage" => to})
  end
end
