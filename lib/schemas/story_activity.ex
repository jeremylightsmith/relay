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

  @doc "Changeset for an activity's editable attributes. `board_id` must already be set on the struct."
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:name, :position])
    |> validate_required([:name, :position])
  end
end
