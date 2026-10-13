defmodule Relay.Repo.Migrations.AddExampleTemplateToBoards do
  use Ecto.Migration

  # RE444: marks a board as the public example for one template slug. Nullable; at most one
  # board per slug.
  def change do
    alter table(:boards) do
      add :example_template, :string, null: true
    end

    create unique_index(:boards, [:example_template])
  end
end
