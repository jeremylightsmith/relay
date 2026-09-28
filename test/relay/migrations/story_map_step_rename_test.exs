# On a pending/CI test DB the `test` alias's `ecto.migrate` compiles this migration in-memory
# before the suite loads, so re-requiring it here would "redefine" the module and abort under
# --warnings-as-errors. Only load it from disk when the migrator hasn't already.
if !Code.ensure_loaded?(Relay.Repo.Migrations.StoryMapStepRename) do
  "priv/repo/migrations/*_story_map_step_rename.exs"
  |> Path.wildcard()
  |> List.first()
  |> Code.require_file()
end

defmodule Relay.Migrations.StoryMapStepRenameTest do
  @moduledoc """
  RE354 — the data half of the story-map Task → Step rename: the persisted
  `boards.story_map_view` key. The DDL half (table, sequence, indexes, constraints and the card
  column) is exercised by every test that touches `Schemas.StoryStep` or `cards.story_step_id`.
  The old key is read off the migration itself, so this file never spells the retired word.
  """
  use Relay.DataCase, async: true

  alias Relay.Repo
  alias Relay.Repo.Migrations.StoryMapStepRename, as: Migration

  test "the new key is the one Relay.StoryMap owns" do
    {old, new} = Migration.view_key_rename()

    assert Map.has_key?(Relay.StoryMap.view_defaults(), new)
    refute Map.has_key?(Relay.StoryMap.view_defaults(), old)
  end

  test "up moves the old key's value to the new key; down moves it back" do
    {old, new} = Migration.view_key_rename()
    board = insert(:board)
    set_view!(board.id, %{old => true, "zoom" => "full"})

    Repo.query!(Migration.view_key_sql(:up))

    assert get_view!(board.id) == %{new => true, "zoom" => "full"}
    assert Relay.StoryMap.view(Repo.get!(Schemas.Board, board.id))[new] == true

    Repo.query!(Migration.view_key_sql(:down))

    assert get_view!(board.id) == %{old => true, "zoom" => "full"}
  end

  test "a board whose view lacks the old key is untouched" do
    board = insert(:board)
    set_view!(board.id, %{"zoom" => "map"})

    Repo.query!(Migration.view_key_sql(:up))

    assert get_view!(board.id) == %{"zoom" => "map"}
  end

  defp set_view!(id, view), do: Repo.query!("UPDATE boards SET story_map_view = $1 WHERE id = $2", [view, id])

  defp get_view!(id) do
    %{rows: [[view]]} = Repo.query!("SELECT story_map_view FROM boards WHERE id = $1", [id])
    view
  end
end
