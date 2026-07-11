defmodule Relay.Repo.Migrations.RenameCardStatusReady do
  use Ecto.Migration

  def up do
    # Both old collapsing statuses become :ready. Existing `done` cards sit in the Done stage,
    # so they derive as Done; `queued` cards were already parked. status is a plain string
    # column (app-level Ecto.Enum), so this is a data backfill, not an ALTER TYPE.
    execute "UPDATE cards SET status = 'ready' WHERE status IN ('queued', 'done')"
    alter table(:cards), do: modify(:status, :string, null: false, default: "ready")
  end

  def down do
    # Best-effort: cannot distinguish original queued vs done; restore the old default only.
    alter table(:cards), do: modify(:status, :string, null: false, default: "queued")
  end
end
