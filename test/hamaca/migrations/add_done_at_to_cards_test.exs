# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Hamaca.Repo.Migrations.AddDoneAtToCards) do
  "priv/repo/migrations/*_add_done_at_to_cards.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Hamaca.Migrations.AddDoneAtToCardsTest do
  use Hamaca.DataCase, async: true

  alias Hamaca.Repo.Migrations.AddDoneAtToCards, as: Migration
  alias Schemas.Card

  # A board with a Code stage (carrying a mid-board :done sub-lane) and a terminal Done stage.
  setup do
    board = insert(:board)
    code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 10)
    code_done = insert(:stage, board: board, parent_id: code.id, name: "Code:Done", type: :done, position: 11)
    terminal = insert(:stage, board: board, name: "Done", type: :done, category: :complete, position: 20)

    %{code: code, code_done: code_done, terminal: terminal}
  end

  defp moved_into!(card, stage, inserted_at) do
    insert(:activity,
      card: card,
      type: :moved,
      meta: %{"to_stage" => stage.name, "to_stage_id" => stage.id},
      inserted_at: inserted_at
    )
  end

  test "stamps a terminal card from its latest :moved-into-terminal activity",
       %{code: code, terminal: terminal} do
    card = insert(:card, stage: terminal)
    moved_into!(card, terminal, ~U[2026-09-01 12:00:00Z])
    moved_into!(card, terminal, ~U[2026-10-01 12:00:00Z])
    moved_into!(card, code, ~U[2026-10-15 12:00:00Z])

    assert Migration.backfill(Repo) == 1
    assert Repo.get!(Card, card.id).done_at == ~U[2026-10-01 12:00:00Z]
  end

  test "falls back to updated_at when no :moved-into-terminal activity exists", %{terminal: terminal} do
    card = insert(:card, stage: terminal, updated_at: ~U[2026-08-01 00:00:00Z])

    assert Migration.backfill(Repo) == 1
    assert Repo.get!(Card, card.id).done_at == ~U[2026-08-01 00:00:00Z]
  end

  test "backfills an archived terminal card too", %{terminal: terminal} do
    card = insert(:card, stage: terminal, archived_at: ~U[2026-10-20 00:00:00Z])
    moved_into!(card, terminal, ~U[2026-10-01 12:00:00Z])

    assert Migration.backfill(Repo) == 1
    assert Repo.get!(Card, card.id).done_at == ~U[2026-10-01 12:00:00Z]
  end

  test "leaves cards outside the terminal stage without done_at, including a :done sub-lane",
       %{code: code, code_done: code_done} do
    in_code = insert(:card, stage: code)
    in_code_done = insert(:card, stage: code_done)
    moved_into!(in_code_done, code_done, ~U[2026-10-01 12:00:00Z])

    assert Migration.backfill(Repo) == 0
    assert Repo.get!(Card, in_code.id).done_at == nil
    assert Repo.get!(Card, in_code_done.id).done_at == nil
  end

  test "a second run touches nothing (idempotent)", %{terminal: terminal} do
    card = insert(:card, stage: terminal)
    moved_into!(card, terminal, ~U[2026-10-01 12:00:00Z])

    assert Migration.backfill(Repo) == 1
    assert Migration.backfill(Repo) == 0
    assert Repo.get!(Card, card.id).done_at == ~U[2026-10-01 12:00:00Z]
  end
end
