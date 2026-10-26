defmodule Hamaca.Repo.Migrations.CreateSetupMachines do
  use Ecto.Migration

  # RE446: per-machine setup ("connect a machine"). A machine's checklist rows live in
  # `board_setup_steps` beside the board's own, told apart by `machine_id` (nil for the board's), so
  # the board-wide `(board_id, step)` uniqueness becomes two partial indexes.
  def change do
    create table(:setup_machines) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, on_delete: :nilify_all)
      add :host, :string
      add :runner_name, :string

      timestamps(type: :utc_datetime)
    end

    create index(:setup_machines, [:board_id])
    create index(:setup_machines, [:api_key_id])

    drop unique_index(:board_setup_steps, [:board_id, :step])

    alter table(:board_setup_steps) do
      add :machine_id, references(:setup_machines, on_delete: :delete_all)
    end

    create unique_index(:board_setup_steps, [:board_id, :step],
             where: "machine_id IS NULL",
             name: :board_setup_steps_board_step_index
           )

    create unique_index(:board_setup_steps, [:machine_id, :step],
             where: "machine_id IS NOT NULL",
             name: :board_setup_steps_machine_step_index
           )
  end
end
