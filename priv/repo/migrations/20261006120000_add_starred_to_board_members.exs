defmodule Relay.Repo.Migrations.AddStarredToBoardMembers do
  use Ecto.Migration

  # RE395 — a personal board star: one flag per user per board, on the membership row (so it
  # goes away with the membership). Drives the starred-first A–Z display order of the user's
  # boards. Written only through Relay.Boards.set_starred/3; the default covers existing rows.
  def change do
    alter table(:board_members) do
      add :starred, :boolean, null: false, default: false
    end
  end
end
