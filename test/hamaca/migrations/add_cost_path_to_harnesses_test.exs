# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.AddCostPathToHarnesses) do
  "priv/repo/migrations/*_add_cost_path_to_harnesses.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.AddCostPathToHarnessesTest do
  @moduledoc """
  RE516 — every existing board's `claude-code` harness gets the frozen `.total_cost_usd` cost
  path; other harnesses, and a cost path somebody already set, are left alone.
  """
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo
  alias Hamaca.Repo.Migrations.AddCostPathToHarnesses, as: Migration

  defp insert_harness!(board_id, key, cost_path) do
    Repo.query!(
      """
      INSERT INTO harnesses (board_id, key, name, command, models, cost_path, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'x {prompt}', $4, $5, now(), now())
      """,
      [board_id, key, key, ["m"], cost_path]
    )
  end

  defp cost_path(board_id, key) do
    %{rows: [[cost_path]]} =
      Repo.query!("SELECT cost_path FROM harnesses WHERE board_id = $1 AND key = $2", [board_id, key])

    cost_path
  end

  defp seed_rows! do
    board = insert(:board)
    for key <- ["claude-code", "codex", "gemini"], do: insert_harness!(board.id, key, nil)

    other = insert(:board)
    insert_harness!(other.id, "claude-code", ".mine")

    {board, other}
  end

  defp assert_backfilled(board, other) do
    assert cost_path(board.id, "claude-code") == ".total_cost_usd"
    assert cost_path(board.id, "codex") == nil
    assert cost_path(board.id, "gemini") == nil
    assert cost_path(other.id, "claude-code") == ".mine"
  end

  # Task 1 · Scenario 8
  test "backfill!/1 gives claude-code harnesses .total_cost_usd and leaves the rest alone" do
    {board, other} = seed_rows!()

    Migration.backfill!(Repo)

    assert_backfilled(board, other)
  end

  # Task 1 · Scenario 9
  test "backfill!/1 is idempotent" do
    {board, other} = seed_rows!()

    Migration.backfill!(Repo)
    Migration.backfill!(Repo)

    assert_backfilled(board, other)
  end
end
