defmodule Relay.Repo.Migrations.FreemiumLaunch do
  use Ecto.Migration

  # RE469 — the one-time launch of the Free plan, which replaces the 30-day trial. Data-only; no
  # schema change; a second run is a no-op.
  #
  # 1. Every never-paid (`paid_through IS NULL`), uncomped, unheld account — today's trial and
  #    trial-ended owners — that owns more than one counted board (live: `archived_at IS NULL`,
  #    not a template example: `example_template IS NULL`) is comped, with a `comp` admin entry
  #    (`actor_id` NULL) naming the board count so the superadmin can do the manual outreach.
  #    Everyone else is left alone and now reads as Free. Idempotency comes from the filter:
  #    a second pass finds those accounts comped and skips them.
  # 2. `billing_notices` rows of the kinds RE469 retired are rewritten so
  #    `Schemas.BillingNotice` keeps loading: `paused` becomes `dropped_to_free` with its
  #    `period_key` shifted by the 1-day grace (the dropped-to-Free notice's period is
  #    `paid_through + grace + 1`, so that lapse's notice counts as already sent), and
  #    `trial_ending` rows are deleted.
  #
  # Raw SQL only — a migration must not call app modules (`Relay.Billing`, `Schemas.*`), which
  # change after it is written. The literals below ('comp', 'paused', 'dropped_to_free',
  # 'trial_ending', the 1-day shift) are frozen copies of those closed sets and policy numbers as
  # they stood at launch; this is the one place the retired values may appear.

  def up do
    backfill(repo())
    :ok
  end

  # The launch can't be un-comped automatically: a comp may since have been confirmed by hand.
  def down, do: :ok

  @doc false
  def backfill(repo) do
    %{num_rows: comped} =
      repo.query!("""
      WITH targets AS (
        SELECT a.id, count(b.id) AS boards
        FROM billing_accounts a
        JOIN boards b
          ON b.owner_id = a.user_id AND b.archived_at IS NULL AND b.example_template IS NULL
        WHERE a.paid_through IS NULL AND NOT a.comped AND a.held_on IS NULL
        GROUP BY a.id
        HAVING count(b.id) > 1
      ),
      comped AS (
        UPDATE billing_accounts a
        SET comped = true, updated_at = now()
        FROM targets t
        WHERE a.id = t.id
        RETURNING a.id, t.boards
      )
      INSERT INTO billing_admin_entries (billing_account_id, actor_id, action, reason, inserted_at)
      SELECT id, NULL, 'comp', 'freemium launch: trial owner with ' || boards || ' boards', now()
      FROM comped
      """)

    %{num_rows: notices_renamed} =
      repo.query!("""
      UPDATE billing_notices
      SET kind = 'dropped_to_free', period_key = period_key + 1
      WHERE kind = 'paused'
      """)

    %{num_rows: notices_deleted} =
      repo.query!("DELETE FROM billing_notices WHERE kind = 'trial_ending'")

    %{comped: comped, notices_renamed: notices_renamed, notices_deleted: notices_deleted}
  end
end
