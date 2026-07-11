defmodule Relay.Repo.Migrations.AddKindToComments do
  use Ecto.Migration

  def change do
    alter table(:comments) do
      add :kind, :string, null: false, default: "comment"
    end
  end
end
