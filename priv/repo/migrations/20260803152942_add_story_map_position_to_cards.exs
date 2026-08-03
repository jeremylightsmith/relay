defmodule Relay.Repo.Migrations.AddStoryMapPositionToCards do
  use Ecto.Migration

  # RE262 — the card's order within its story-map CELL. Nullable and deliberately unbackfilled:
  # nil means "nobody has ordered this card on the map yet", and the sort rule (ascending, nils
  # last) makes that total rather than an edge case. No unique index — a renumber never needs
  # temporary values (same reasoning as StoryActivity.position). No new index at all: the one
  # query that filters on the cell triple is board-scoped and already covered by RE265's FK
  # indexes.
  def change do
    alter table(:cards) do
      add :story_map_position, :integer
    end
  end
end
