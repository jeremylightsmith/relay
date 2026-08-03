defmodule Schemas.StoryTask do
  @moduledoc """
  A story-map **Task** (RE265): one step under an Activity — the backbone of the story map.
  Ordered by `position` *within* its activity.

  `board_id` is denormalized here on purpose (it is already reachable through the activity) so
  every read is a single board-scoped `where` and a cross-board task cannot be smuggled into a
  query that only filters on `board_id`. It is set from the parent activity by
  `Relay.StoryMap.create_task/2` and is never cast from input. `story_activity_id` *is* cast —
  `Relay.StoryMap.update_task/2` may move a task to another activity on the **same** board and
  rejects a cross-board move.

  Named `StoryTask`, not `Task`, because a bare `Schemas.Task` shadows OTP's `Task` on `alias`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "story_tasks" do
    field :name, :string
    field :position, :integer

    belongs_to :board, Schemas.Board
    belongs_to :story_activity, Schemas.StoryActivity

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a task's editable attributes, including a move to another activity.
  `board_id` must already be set on the struct; the same-board rule for
  `story_activity_id` is enforced by `Relay.StoryMap.update_task/2`.

  `name` is capped by `Schemas.StoryActivity.max_name_length/0` — the one definition of the
  story-map name cap; the column is `varchar(255)`, so an unvalidated paste raises Postgrex
  22001 instead of returning an error changeset.
  """
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:name, :position, :story_activity_id])
    |> validate_required([:name, :position, :story_activity_id])
    |> validate_length(:name, min: 1, max: Schemas.StoryActivity.max_name_length())
    |> foreign_key_constraint(:story_activity_id)
  end
end
