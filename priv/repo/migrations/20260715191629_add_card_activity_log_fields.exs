defmodule Relay.Repo.Migrations.AddCardActivityLogFields do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :text, :text
      add :run_id, :string
    end

    alter table(:cards) do
      add :agent_heartbeat_at, :utc_datetime
    end

    # Serves ONLY Relay.Activity.Pruner's `type = 'action' AND inserted_at < cutoff`
    # sweep. The existing index(:activities, [:card_id, :inserted_at]) already serves
    # the timeline and the newest-per-card query.
    create index(:activities, [:inserted_at],
             where: "type = 'action'",
             name: :activities_action_pruning_index
           )
  end
end
