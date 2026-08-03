defmodule Schemas.Release do
  @moduledoc """
  A story-map **Release** (RE265): one swimlane down the left of the story map, and a **new
  axis orthogonal to stage** — a card has both a stage and (optionally) a release.

  Every board is seeded with `seed_names/0` — MVP / Fast follow / Later — all fully editable
  afterwards. `board_id` is set programmatically, never cast. A card's `release_id` is
  genuinely optional and independent of its activity/task: a card can be mapped to a cell
  with its release still undecided.

  Not to be confused with `Relay.Release`, the Phoenix release-task module — different
  namespace, no collision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "releases" do
    field :name, :string
    field :position, :integer

    belongs_to :board, Schemas.Board

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a release's editable attributes. `board_id` must already be set on the struct.

  `name` is trimmed and capped by `Schemas.StoryActivity.max_name_length/0` — the one
  definition of the story-map name cap; the column is `varchar(255)`, so an unvalidated paste
  raises Postgrex 22001 instead of returning an error changeset.
  """
  def changeset(release, attrs) do
    release
    |> cast(attrs, [:name, :position])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :position])
    |> validate_length(:name, min: 1, max: Schemas.StoryActivity.max_name_length())
  end

  @doc """
  The releases every board is seeded with, in `position` order — the ONE definition.
  `Relay.Boards.create_board/2`'s seed and the tests all read it here. The
  `backfill_story_map_releases` migration carries a deliberately frozen copy, pinned to this
  list by `test/relay/migrations/backfill_story_map_releases_test.exs`.
  """
  def seed_names, do: ["MVP", "Fast follow", "Later"]
end
