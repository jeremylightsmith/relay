defmodule Relay.Repo.Migrations.RepairSublaneNames do
  use Ecto.Migration

  # RE385 — a substage's stored `name` is its API identifier and must equal
  # `"<parent name>:Review"` / `"<parent name>:Done"`. Before `Boards.update_stage/2` cascaded a
  # rename, renaming a main stage left its substages on the old name (`Specify` over
  # `Spec:Review`). This repairs every drifted substage once; re-running is a no-op because the
  # WHERE skips rows that already match (so their `updated_at` is never touched).
  #
  # The `'review' → 'Review'` / `'done' → 'Done'` mapping and the `':'` separator are a FROZEN
  # copy of `Schemas.Stage.sublane_types/0` and `Boards`' composite-name format — the one
  # sanctioned exception to the magic-value rule: a migration must replay identically forever, so
  # it never calls app code that may change after it ships. The type is mapped explicitly (never
  # `initcap(type)`) and restricted to the two sub-lane types, so a stray child type is left alone.
  # Only rows with a parent are touched; a main stage never is.

  @doc "The data repair — one UPDATE, also exactly what its test executes."
  @spec repair_sql() :: String.t()
  def repair_sql do
    """
    UPDATE stages AS child
    SET name = parent.name || ':' || CASE child.type WHEN 'review' THEN 'Review' WHEN 'done' THEN 'Done' END,
        updated_at = (now() AT TIME ZONE 'UTC')
    FROM stages AS parent
    WHERE child.parent_id = parent.id
      AND child.type IN ('review', 'done')
      AND child.name IS DISTINCT FROM
        parent.name || ':' || CASE child.type WHEN 'review' THEN 'Review' WHEN 'done' THEN 'Done' END
    """
  end

  def up, do: execute(repair_sql())

  # No schema change, and the drifted names are not worth restoring.
  def down, do: :ok
end
