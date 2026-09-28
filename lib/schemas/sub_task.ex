defmodule Schemas.SubTask do
  @moduledoc """
  A single task on a card (RLY-18; addressable since RE355). The Plan stage writes the list
  (`Relay.Cards.set_sub_tasks/2`, the legacy full replace, or the per-task
  `Relay.Cards.add_tasks/2` / `update_task/3` / `delete_task/2`) and the Code stage checks items
  off (`Relay.Cards.set_sub_task_done/3`) as it works; the drawer's SUB-TASKS panel derives its
  done/total progress from the list. `body` is the task's own markdown (nullable). `card_id` and
  `position` are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "sub_tasks" do
    field :title, :string
    field :body, :string
    field :done, :boolean, default: false
    field :position, :integer

    belongs_to :card, Schemas.Card

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts the user/agent-supplied `:title`, `:done` and `:body`; `card_id` and `position`
  must already be set on the struct and are never cast.
  """
  def changeset(sub_task, attrs) do
    sub_task
    |> cast(attrs, [:title, :done, :body])
    |> validate_required([:title])
    |> foreign_key_constraint(:card_id)
  end
end
