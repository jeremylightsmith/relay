# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.FlowsBelongToOneStage) do
  "priv/repo/migrations/*_flows_belong_to_one_stage.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.FlowsBelongToOneStageTest do
  @moduledoc """
  RE429 — a flow belongs to exactly one stage. Before `flows.stage_id` goes NOT NULL and unique,
  the migration prunes flows with no stage and every extra flow sharing a stage (keeping the
  enabled one first, then the lowest key). The test DB is already migrated, so only the pure
  pruning rule is exercised here.
  """
  use ExUnit.Case, async: true

  alias Relay.Repo.Migrations.FlowsBelongToOneStage, as: Migration

  test "flows_to_delete/1 drops stageless flows and all but one flow per stage" do
    rows = [
      %{id: 1, board_id: 9, key: "a", stage_id: nil, enabled: true},
      %{id: 2, board_id: 9, key: "zz", stage_id: 5, enabled: false},
      %{id: 3, board_id: 9, key: "mm", stage_id: 5, enabled: true},
      %{id: 4, board_id: 9, key: "bb", stage_id: 5, enabled: true},
      %{id: 5, board_id: 9, key: "ok", stage_id: 6, enabled: false}
    ]

    deleted = rows |> Migration.flows_to_delete() |> Enum.sort_by(& &1.id)

    assert Enum.map(deleted, & &1.id) == [1, 2, 3]

    assert [
             %{id: 1, board_id: 9, key: "a", reason: "no stage"},
             %{id: 2, board_id: 9, key: "zz", reason: "stage 5 keeps flow `bb`"},
             %{id: 3, board_id: 9, key: "mm", reason: "stage 5 keeps flow `bb`"}
           ] = deleted
  end
end
