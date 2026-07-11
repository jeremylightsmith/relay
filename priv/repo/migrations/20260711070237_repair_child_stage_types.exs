defmodule Relay.Repo.Migrations.RepairChildStageTypes do
  use Ecto.Migration

  @moduledoc """
  Follow-up to `add_stage_types` (20260711051905). That migration's CASE never matched
  `parent_id IS NOT NULL AND lane = 'done'` against real data, so every pre-existing Done
  sub-lane came out of it as `work`/`queue` — a value the model's own
  `Schemas.Stage.validate_child_type/1` forbids for a child stage (must be `review`/`done`),
  and one `RelayWeb.BoardLive.lane_order/1` isn't total over (500s the board view). This
  data-only repair snaps any already-migrated child stage back onto a valid type; it's
  idempotent and a no-op on a DB where the corrected `add_stage_types` logic already ran.
  """

  def up do
    execute("""
    UPDATE stages SET type = CASE
      WHEN name ILIKE '%review%' THEN 'review'
      ELSE 'done'
    END
    WHERE parent_id IS NOT NULL AND type NOT IN ('review', 'done')
    """)
  end

  def down do
    # Data repair only — not reversible (the pre-repair type is not recoverable).
    :ok
  end
end
