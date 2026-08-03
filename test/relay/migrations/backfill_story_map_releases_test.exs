# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.BackfillStoryMapReleases) do
  "priv/repo/migrations/*_backfill_story_map_releases.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.BackfillStoryMapReleasesTest do
  use ExUnit.Case, async: true

  alias Relay.Repo.Migrations.BackfillStoryMapReleases, as: Migration
  alias Schemas.Release

  test "the migration's frozen names still match the seed vocabulary" do
    assert Migration.release_names() == Release.seed_names()
  end

  test "only boards without releases are seeded — the backfill is idempotent" do
    assert Migration.boards_to_seed([1, 2, 3], [2]) == [1, 3]
    assert Migration.boards_to_seed([1, 2, 3], [1, 2, 3]) == []
    assert Migration.boards_to_seed([], [7]) == []
  end

  test "rows/2 produces the three swimlanes per board, positioned 1..3 and timestamped" do
    now = ~U[2026-08-02 12:00:00Z]

    rows = Migration.rows([7], now)

    assert rows == [
             %{board_id: 7, name: "MVP", position: 1, inserted_at: now, updated_at: now},
             %{board_id: 7, name: "Fast follow", position: 2, inserted_at: now, updated_at: now},
             %{board_id: 7, name: "Later", position: 3, inserted_at: now, updated_at: now}
           ]
  end

  test "rows/2 spans every board it is given" do
    rows = Migration.rows([1, 2], ~U[2026-08-02 12:00:00Z])

    assert length(rows) == 6
    assert rows |> Enum.map(& &1.board_id) |> Enum.uniq() == [1, 2]
  end

  test "rows/2 is empty when there is nothing to seed" do
    assert Migration.rows([], ~U[2026-08-02 12:00:00Z]) == []
  end
end
