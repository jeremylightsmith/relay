defmodule Relay.Repo.Migrations.AddNodeJobIdToActivities do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :node_job_id, :string
    end
  end
end
