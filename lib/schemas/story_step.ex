defmodule Schemas.StoryStep do
  @moduledoc """
  A story-map **Step** (RE265, renamed from Task in RE354): one step under an Activity — the
  backbone of the story map. Ordered by `position` *within* its activity.

  `board_id` is denormalized here on purpose (it is already reachable through the activity) so
  every read is a single board-scoped `where` and a cross-board step cannot be smuggled into a
  query that only filters on `board_id`. It is set from the parent activity by
  `Relay.StoryMap.create_step/2` and is never cast from input. `story_activity_id` *is* cast —
  `Relay.StoryMap.update_step/2` may move a step to another activity on the **same** board and
  rejects a cross-board move.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "story_steps" do
    field :name, :string
    field :position, :integer

    belongs_to :board, Schemas.Board
    belongs_to :story_activity, Schemas.StoryActivity

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a step's editable attributes, including a move to another activity.
  `board_id` must already be set on the struct; the same-board rule for
  `story_activity_id` is enforced by `Relay.StoryMap.update_step/2`.

  `name` is trimmed and capped by `Schemas.StoryActivity.max_name_length/0` — the one
  definition of the story-map name cap; the column is `varchar(255)`, so an unvalidated paste
  raises Postgrex 22001 instead of returning an error changeset.
  """
  def changeset(step, attrs) do
    step
    |> cast(attrs, [:name, :position, :story_activity_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :position, :story_activity_id])
    |> validate_length(:name, min: 1, max: Schemas.StoryActivity.max_name_length())
    |> foreign_key_constraint(:story_activity_id)
  end
end
