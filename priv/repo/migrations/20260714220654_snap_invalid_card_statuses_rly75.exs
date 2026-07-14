defmodule Relay.Repo.Migrations.SnapInvalidCardStatusesRly75 do
  use Ecto.Migration

  # One-time data repair (RLY-75): the runner's Code→Review hand-off set `:ready` on cards
  # arriving in a review-type stage (should be `:in_review`), and the API used to persist
  # stage-invalid statuses. Both are fixed going forward (runner line removed;
  # `Cards.set_status_snapped/3` enforces validity at the API). This snaps every card whose
  # (status, stage.type) combo is currently invalid to that type's default_status — same
  # statements as the RLY-57 repair, re-run for rows that drifted since. Data-only; no schema
  # change; safe to no-op on re-run.

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
