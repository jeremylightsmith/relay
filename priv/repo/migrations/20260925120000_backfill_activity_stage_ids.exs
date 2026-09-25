defmodule Relay.Repo.Migrations.BackfillActivityStageIds do
  @moduledoc """
  RE146 — `:moved` / `:approved` / `:rejected` rows now carry `from_stage_id` / `to_stage_id`
  in `meta`. Rows written before that only snapshotted display names, so this resolves each
  name against the **card's board** and, per decision 1, DELETES any row whose from- or
  to-name matches zero stages (renamed) or more than one (ambiguous). Data-only; `down` is a
  no-op. Plain SQL, so it never depends on app modules that may change.
  """
  use Ecto.Migration

  def up do
    {resolved, deleted} = backfill(repo())

    IO.puts(
      "backfill_activity_stage_ids: resolved #{resolved} row(s), deleted #{deleted} unresolvable row(s)"
    )
  end

  def down, do: :ok

  @doc "Runs the backfill against `repo`, returning `{resolved, deleted}` row counts."
  def backfill(repo) do
    %{num_rows: resolved} = repo.query!(resolve_sql())
    %{num_rows: deleted} = repo.query!(delete_sql())
    {resolved, deleted}
  end

  # The stage display-name rule, reproduced ONCE here in SQL — it mirrors
  # Relay.Boards.stage_display_name/1 + lane_word/1: a main stage displays its `name`, a
  # substage displays "<parent name> · Review" or "<parent name> · Done". Only a name that
  # matches exactly one stage on the card's board resolves.
  defp resolve_sql do
    """
    WITH display AS (
      SELECT s.id, s.board_id,
             CASE WHEN s.parent_id IS NULL THEN s.name
                  WHEN s.type = 'review' THEN p.name || ' · Review'
                  WHEN s.type = 'done' THEN p.name || ' · Done'
             END AS name
      FROM stages AS s
      LEFT JOIN stages AS p ON p.id = s.parent_id
    ),
    unique_names AS (
      SELECT board_id, name, min(id) AS id
      FROM display
      WHERE name IS NOT NULL
      GROUP BY board_id, name
      HAVING count(*) = 1
    )
    UPDATE activities AS a
    SET meta = a.meta || jsonb_build_object('from_stage_id', f.id, 'to_stage_id', t.id)
    FROM cards AS c, unique_names AS f, unique_names AS t
    WHERE a.card_id = c.id
      AND a.type IN ('moved', 'approved', 'rejected')
      AND NOT (a.meta ? 'from_stage_id')
      AND f.board_id = c.board_id AND f.name = a.meta->>'from_stage'
      AND t.board_id = c.board_id AND t.name = a.meta->>'to_stage'
    """
  end

  # Whatever the resolve pass could not stamp is, by decision 1, unrecoverable history.
  defp delete_sql do
    """
    DELETE FROM activities
    WHERE type IN ('moved', 'approved', 'rejected')
      AND NOT (meta ? 'from_stage_id')
    """
  end
end
