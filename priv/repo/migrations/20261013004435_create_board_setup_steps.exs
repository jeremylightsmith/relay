defmodule Hamaca.Repo.Migrations.CreateBoardSetupSteps do
  use Ecto.Migration

  # RE443: the board-owned setup checklist, one row per (board, catalog step), and the per-user
  # "hide explanations" preference the checklist reads.
  def change do
    create table(:board_setup_steps) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :step, :string, null: false
      add :status, :string, null: false
      add :reached_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :evidence, :text
      add :error, :text
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_setup_steps, [:board_id, :step])

    alter table(:users) do
      add :setup_explanations_hidden, :boolean, null: false, default: false
    end
  end
end
