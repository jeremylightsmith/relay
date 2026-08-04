defmodule Relay.Repo.Migrations.AddStoryMapViewToBoards do
  use Ecto.Migration

  def change do
    # RE257 — the board's SHARED story-map view settings. A bag, not columns: the key set is
    # owned by Relay.StoryMap.view_defaults/0 and RE259/RE260 extend it there without a
    # migration each. Persisted rather than held in ETS or a GenServer on purpose — someone
    # who opens the map an hour later must see the same view as everyone already on it, and
    # the write rate is "a human clicked a toggle".
    alter table(:boards) do
      add :story_map_view, :map, null: false, default: %{}
    end
  end
end
