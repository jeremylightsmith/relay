defmodule Relay.Repo.Migrations.RemoveAiEnabledFromStages do
  @moduledoc """
  RE409: "AI-enabled" is no longer a stage setting — a stage is AI-enabled iff a flow works in it
  (`Relay.Flows.ai_stage_ids/1`). `down` re-adds the column and backfills it from flows, for the
  work/planning stages only (the old changeset forced every other type to `false`).
  """
  use Ecto.Migration

  def up do
    alter table(:stages) do
      remove :ai_enabled
    end
  end

  def down do
    alter table(:stages) do
      add :ai_enabled, :boolean, default: false, null: false
    end

    flush()

    execute("""
    UPDATE stages SET ai_enabled = TRUE
    WHERE type IN ('work','planning')
      AND EXISTS (SELECT 1 FROM flows f WHERE f.works_in_stage_id = stages.id)
    """)
  end
end
