defmodule Relay.Repo.Migrations.SnapInvalidCardStatusesToTypeDefault do
  use Ecto.Migration

  # One-time data repair (RLY-57): the runner and older move paths left cards in states that are
  # invalid for their stage type — notably `:in_review`/`:working` cards parked in a `:done`
  # stage. Going forward `move_card` snaps status to the type's default (Schemas.Stage matrix),
  # but pre-existing rows need fixing. Snap every card whose (status, stage.type) combo is
  # invalid to that type's default_status. Data-only; no schema change; safe to no-op on re-run.

  def up do
    # done: only :ready
    execute("""
    UPDATE cards c SET status = 'ready'
    FROM stages s WHERE c.stage_id = s.id AND s.type = 'done' AND c.status <> 'ready'
    """)

    # review: only :in_review
    execute("""
    UPDATE cards c SET status = 'in_review'
    FROM stages s WHERE c.stage_id = s.id AND s.type = 'review' AND c.status <> 'in_review'
    """)

    # queue: only :ready
    execute("""
    UPDATE cards c SET status = 'ready'
    FROM stages s WHERE c.stage_id = s.id AND s.type = 'queue' AND c.status <> 'ready'
    """)

    # work / planning: :working | :ready | :needs_input, else default :working
    execute("""
    UPDATE cards c SET status = 'working'
    FROM stages s
    WHERE c.stage_id = s.id AND s.type IN ('work', 'planning')
      AND c.status NOT IN ('working', 'ready', 'needs_input')
    """)
  end

  # Irreversible data repair — the prior invalid statuses are not recoverable, and
  # re-introducing them would recreate the bug. Down is a no-op.
  def down, do: :ok
end
