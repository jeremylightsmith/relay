# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.RepairSublaneNames) do
  "priv/repo/migrations/*_repair_sublane_names.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.RepairSublaneNamesTest do
  @moduledoc """
  RE385 — a substage's stored name must equal `"<parent name>:Review|Done"`. Before the rename
  cascade, renaming a main stage left its substages on the old name (`Specify` / `Spec:Review`);
  this data migration repairs that drift and is a no-op on rows that are already correct.
  """
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Repo
  alias Relay.Repo.Migrations.RepairSublaneNames, as: Migration

  setup do
    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Drift board"})
    %{board: board, user: user}
  end

  test "repairs substages whose names drifted from their renamed parent", %{board: board} do
    raw_rename_main!(board, "Spec", "Specify")

    assert %{num_rows: 2} = Repo.query!(Migration.repair_sql())

    assert child_names(board, "Specify") == %{review: "Specify:Review", done: "Specify:Done"}
  end

  test "a second run touches nothing", %{board: board} do
    raw_rename_main!(board, "Spec", "Specify")
    Repo.query!(Migration.repair_sql())
    before = names(board)

    assert %{num_rows: 0} = Repo.query!(Migration.repair_sql())
    assert names(board) == before
  end

  test "only drifted children change; correct boards and main stages are left alone",
       %{board: fresh, user: user} do
    {:ok, drifted} = Relay.Boards.create_board(user, %{name: "Second board"})
    raw_rename_main!(drifted, "Plan", "Design")
    fresh_before = names(fresh)
    mains_before = main_names(drifted)

    assert %{num_rows: 1} = Repo.query!(Migration.repair_sql())

    assert names(fresh) == fresh_before
    assert child_names(fresh, "Spec") == %{review: "Spec:Review", done: "Spec:Done"}
    assert child_names(fresh, "Plan") == %{done: "Plan:Done"}
    assert child_names(drifted, "Design") == %{done: "Design:Done"}
    assert main_names(drifted) == mains_before
  end

  test "maps a review child to :Review and a done child to :Done", %{board: board} do
    raw_rename_main!(board, "Spec", "Build")

    Repo.query!(Migration.repair_sql())

    assert child_names(board, "Build") == %{review: "Build:Review", done: "Build:Done"}
  end

  # Renames a main stage behind the context's back — `Boards.update_stage/2` cascades to the
  # substages, so it can't produce the drift this migration repairs. The children keep their old
  # stored names; one is re-asserted explicitly to make the drift visible.
  defp raw_rename_main!(board, from, to) do
    parent = main_stage!(board, from)
    Repo.update_all(from(s in Schemas.Stage, where: s.id == ^parent.id), set: [name: to])

    Repo.update_all(
      from(s in Schemas.Stage, where: s.parent_id == ^parent.id and s.type == :done),
      set: [name: "#{from}:Done"]
    )

    parent.id
  end

  defp child_names(board, parent_name) do
    parent = main_stage!(board, parent_name)

    from(s in Schemas.Stage, where: s.parent_id == ^parent.id, select: {s.type, s.name})
    |> Repo.all()
    |> Map.new()
  end

  defp main_stage!(board, name) do
    Repo.one!(
      from(s in Schemas.Stage,
        where: s.board_id == ^board.id and s.name == ^name and is_nil(s.parent_id)
      )
    )
  end

  defp names(board) do
    from(s in Schemas.Stage, where: s.board_id == ^board.id, select: {s.id, s.name})
    |> Repo.all()
    |> Map.new()
  end

  defp main_names(board) do
    from(s in Schemas.Stage,
      where: s.board_id == ^board.id and is_nil(s.parent_id),
      select: {s.id, s.name}
    )
    |> Repo.all()
    |> Map.new()
  end
end
