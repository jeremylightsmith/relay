defmodule Relay.Repo.Migrations.RenameSubTasksToTasksInFlows do
  use Ecto.Migration

  # RE367 — the flow contract's `sub_tasks` spellings became `tasks`. `Schemas.Card.contract_fields/0`
  # dropped `:sub_tasks`, so a stored node still listing "sub_tasks" in `reads`/`writes` would
  # fail `Ecto.Enum` on load; and the `flow_versions` snapshots pin mid-run cards, so both tables
  # move.
  #
  # The pairs below are a FROZEN copy of `Schemas.Flow.Node`'s legacy-alias table — the one
  # sanctioned exception to the magic-value rule: a migration must replay identically forever, so
  # it never calls app code that may change after it ships.
  #
  # Each pair is a literal substring of the nodes' jsonb text, and they are disjoint: `"sub_tasks"`
  # needs a quote directly before `sub_tasks` (so it never matches inside `"card.sub_tasks"`, nor an
  # escaped `\"sub_tasks\"` inside a `run` prompt), and `{sub_task}` needs its closing brace (so it
  # never matches inside `{sub_task_id}`). `down` reverses each pair; it would also rename a JSON
  # string that is exactly "tasks" (e.g. a node keyed `tasks`) — acceptable for a rollback.
  @renames [
    {~s("sub_tasks"), ~s("tasks")},
    {"card.sub_tasks", "card.tasks"},
    {"{sub_task_id}", "{task_id}"},
    {"{sub_task}", "{task}"}
  ]

  @tables ~w(flows flow_versions)

  @doc "The frozen `{legacy, canonical}` substring pairs this migration rewrites."
  def renames, do: @renames

  @doc "The data rewrite in `direction`, one UPDATE per table — also exactly what its test executes."
  def rewrite_sql(direction) when direction in [:up, :down] do
    pairs =
      if direction == :up,
        do: @renames,
        else: Enum.map(@renames, fn {legacy, canonical} -> {canonical, legacy} end)

    rewritten =
      Enum.reduce(pairs, "nodes::text", fn {from, to}, acc ->
        "replace(#{acc}, '#{from}', '#{to}')"
      end)

    for table <- @tables do
      "UPDATE #{table} SET nodes = (#{rewritten})::jsonb WHERE nodes IS NOT NULL AND (#{rewritten}) <> nodes::text"
    end
  end

  def up, do: Enum.each(rewrite_sql(:up), &execute/1)

  def down, do: Enum.each(rewrite_sql(:down), &execute/1)
end
