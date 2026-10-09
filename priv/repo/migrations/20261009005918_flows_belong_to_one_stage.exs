defmodule Relay.Repo.Migrations.FlowsBelongToOneStage do
  @moduledoc """
  RE429: a flow belongs to exactly one stage. `works_in_stage_id` becomes `stage_id`
  (`NOT NULL`, unique, `on_delete: :delete_all` — deleting a stage deletes its flow, while
  `runs.flow_id` is nilified and `runs.flow_key` survives). Pickup and drop-off are no longer
  stored: `pulls_from_stage_id`, `lands_on_stage_id` and the one-enabled-per-pulls-from index go.

  Before the constraints land, `up` prunes the rows that can't satisfy them (`flows_to_delete/1`):
  every flow with no stage, and every extra flow sharing a stage — the kept one is the enabled
  flow first, then the lowest key. Each deleted flow is logged.

  `down` restores the three nullable trigger columns. `works_in_stage_id` is backfilled from
  `stage_id`; `pulls_from_stage_id` / `lands_on_stage_id` are left nil (the derivation lives in
  `Relay.Flows.neighbours/2` and is not repeated in SQL), so a rolled-back flow must have its
  pickup and drop-off re-pointed before it can be enabled. Pruned flows are not restored.
  """
  use Ecto.Migration

  require Logger

  def up do
    prune!()

    execute("DROP INDEX IF EXISTS flows_one_enabled_per_pulls_from_index")
    drop_if_exists index(:flows, [:pulls_from_stage_id])
    drop_if_exists index(:flows, [:lands_on_stage_id])
    drop_if_exists index(:flows, [:works_in_stage_id])
    execute("ALTER TABLE flows DROP CONSTRAINT IF EXISTS flows_works_in_stage_id_fkey")

    rename table(:flows), :works_in_stage_id, to: :stage_id

    alter table(:flows) do
      modify :stage_id, references(:stages, on_delete: :delete_all), null: false
      remove :pulls_from_stage_id
      remove :lands_on_stage_id
    end

    create unique_index(:flows, [:stage_id], name: :flows_stage_id_index)
  end

  def down do
    drop_if_exists index(:flows, [:stage_id], name: :flows_stage_id_index)
    execute("ALTER TABLE flows DROP CONSTRAINT IF EXISTS flows_stage_id_fkey")

    rename table(:flows), :stage_id, to: :works_in_stage_id

    alter table(:flows) do
      modify :works_in_stage_id, references(:stages, on_delete: :nilify_all), null: true
      add :pulls_from_stage_id, references(:stages, on_delete: :nilify_all)
      add :lands_on_stage_id, references(:stages, on_delete: :nilify_all)
    end

    create index(:flows, [:pulls_from_stage_id])
    create index(:flows, [:works_in_stage_id])
    create index(:flows, [:lands_on_stage_id])

    create unique_index(:flows, [:board_id, :pulls_from_stage_id],
             where: "enabled",
             name: :flows_one_enabled_per_pulls_from_index
           )
  end

  @doc """
  The flows the one-stage constraints can't keep, from `rows` of
  `%{id, board_id, key, stage_id, enabled}`: every row with no stage (`reason: "no stage"`) and,
  per stage, every row but the keeper — enabled first, then the lowest key
  (``reason: "stage <id> keeps flow `<key>`"``). Pure.
  """
  def flows_to_delete(rows) do
    {stageless, staged} = Enum.split_with(rows, &is_nil(&1.stage_id))

    extras =
      staged
      |> Enum.group_by(& &1.stage_id)
      |> Enum.flat_map(fn {stage_id, flows} ->
        [keeper | rest] = Enum.sort_by(flows, &{not &1.enabled, &1.key})
        Enum.map(rest, &deletion(&1, "stage #{stage_id} keeps flow `#{keeper.key}`"))
      end)

    Enum.map(stageless, &deletion(&1, "no stage")) ++ extras
  end

  defp deletion(row, reason),
    do: %{id: row.id, board_id: row.board_id, key: row.key, reason: reason}

  defp prune! do
    %{rows: rows} =
      repo().query!("SELECT id, board_id, key, works_in_stage_id, enabled FROM flows")

    doomed =
      rows
      |> Enum.map(fn [id, board_id, key, stage_id, enabled] ->
        %{id: id, board_id: board_id, key: key, stage_id: stage_id, enabled: enabled}
      end)
      |> flows_to_delete()

    for %{board_id: board_id, key: key, reason: reason} <- doomed do
      Logger.warning(
        "FlowsBelongToOneStage: deleting flow board_id=#{board_id} key=#{key} reason=#{reason}"
      )
    end

    if doomed != [] do
      repo().query!("DELETE FROM flows WHERE id = ANY($1)", [Enum.map(doomed, & &1.id)])
    end

    :ok
  end
end
