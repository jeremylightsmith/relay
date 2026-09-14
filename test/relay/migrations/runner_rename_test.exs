# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.RunnerRename) do
  "priv/repo/migrations/*_runner_rename.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.RunnerRenameTest do
  @moduledoc """
  RE319 — the data half of the rename. The DDL half (table, sequence, indexes, constraints,
  columns) is exercised by every test that touches `Schemas.Runner` or the renamed columns.
  The old values are read off the migration itself, so this file never spells the retired word.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.RunnerRename, as: Migration

  test "every renamed stored value lands on a value the Run schema accepts" do
    for {column, _old, new} <- Migration.value_renames() do
      assert String.to_existing_atom(new) in Ecto.Enum.values(Schemas.Run, String.to_existing_atom(column))
    end
  end

  test "up rewrites each stored old value to its new one; down restores it" do
    for {column, old, new} <- Migration.value_renames() do
      run = insert(:run, status: :parked)
      set_raw!(run.id, column, old)

      Enum.each(Migration.value_updates_sql(:up), &Repo.query!/1)

      assert get_raw!(run.id, column) == new
      loaded = Repo.get!(Schemas.Run, run.id)
      assert Map.fetch!(loaded, String.to_existing_atom(column)) == String.to_existing_atom(new)

      Enum.each(Migration.value_updates_sql(:down), &Repo.query!/1)

      assert get_raw!(run.id, column) == old
    end
  end

  test "rows holding any other value are untouched" do
    run = insert(:run, status: :parked, parked_reason: :needs_input)

    Enum.each(Migration.value_updates_sql(:up), &Repo.query!/1)

    assert Repo.get!(Schemas.Run, run.id).parked_reason == :needs_input
  end

  defp set_raw!(id, column, value), do: Repo.query!("UPDATE runs SET #{column} = $1 WHERE id = $2", [value, id])

  defp get_raw!(id, column) do
    %{rows: [[value]]} = Repo.query!("SELECT #{column} FROM runs WHERE id = $1", [id])
    value
  end
end
