defmodule Relay.Repo.Migrations.AddPrUrlToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :pr_url, :string
    end
  end
end
