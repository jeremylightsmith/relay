defmodule Relay.Repo.Migrations.AddMutedToBoardMembers do
  use Ecto.Migration

  # RE406 — a per-member board mute: one flag per user per board, on the membership row (so it
  # goes away with the membership). Stops APNs pushes for this member on this board. Written
  # only through Relay.Boards.set_muted/3; the default covers existing rows.
  def change do
    alter table(:board_members) do
      add :muted, :boolean, null: false, default: false
    end
  end
end
