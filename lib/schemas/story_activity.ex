defmodule Schemas.StoryActivity do
  @moduledoc """
  A story-map **Activity** (RE265): one big user goal, a column group across the top of the
  story map. Board-scoped and ordered by `position` ascending (ties broken by `id`); there is
  deliberately no unique index on `position`, so a reorder never needs temporary values.

  Named `StoryActivity`, not `Activity`, because `Schemas.Activity` is already the card
  activity log. `board_id` is set programmatically from the board, never cast from input.
  Deleting an activity deletes its `Schemas.StoryTask`s (`on_delete: :delete_all`) and
  nilifies `cards.story_activity_id` (`on_delete: :nilify_all`) — structure deletes unmap
  cards, they never delete them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "story_activities" do
    field :name, :string
    field :position, :integer

    belongs_to :board, Schemas.Board
    has_many :story_tasks, Schemas.StoryTask

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for an activity's editable attributes. `board_id` must already be set on the struct.

  `name` is trimmed and capped at `max_name_length/0` — the column is `varchar(255)`, so an
  unvalidated paste raises Postgrex 22001 instead of returning an error changeset, and the trim
  keeps "a padded name stores its padding" a domain rule rather than one call site's habit
  (`Schemas.Board` pairs the same two).
  """
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:name, :position])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :position])
    |> validate_length(:name, min: 1, max: max_name_length())
  end

  @doc """
  The cap on a user-typed story-map name — the ONE definition, shared by `Schemas.StoryTask`
  and `Schemas.Release`. Matches `Schemas.Board`'s own name cap and stays well under the
  `varchar(255)` column.
  """
  def max_name_length, do: 80
end
