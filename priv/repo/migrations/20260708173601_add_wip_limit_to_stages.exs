defmodule Relay.Repo.Migrations.AddWipLimitToStages do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :wip_limit, :integer, null: true
    end
  end
end
