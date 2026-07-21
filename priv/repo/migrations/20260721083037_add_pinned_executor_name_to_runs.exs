defmodule Relay.Repo.Migrations.AddPinnedExecutorNameToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :pinned_executor_name, :string
    end
  end
end
