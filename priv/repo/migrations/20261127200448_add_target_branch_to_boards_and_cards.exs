defmodule Hamaca.Repo.Migrations.AddTargetBranchToBoardsAndCards do
  use Ecto.Migration

  # RE458 — the target branch. A board has a default (`"main"`, backfilled onto every existing
  # board by the column default); a card may override it (`nil` = inherit the board's), and
  # remembers the card it inherited its override from when it was spawned. Deleting that
  # spawner only forgets the pointer — the copied override stays.
  def change do
    alter table(:boards) do
      add :target_branch, :string, null: false, default: "main"
    end

    alter table(:cards) do
      add :target_branch, :string
      add :target_inherited_from_id, references(:cards, on_delete: :nilify_all)
    end

    create index(:cards, [:target_inherited_from_id])
  end
end
