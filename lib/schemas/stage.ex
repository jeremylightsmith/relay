defmodule Schemas.Stage do
  @moduledoc """
  A column on a board. `category` is the board's meaning band (unstarted → planning →
  in_progress → complete). `type` is the stage's **behavior** — one of
  `:queue | :work | :planning | :review | :done` — and drives gates, AI participation, and
  the default card state on entry (see ADR 0003). `category` suggests a default `type`
  (`default_type/1`) when a stage is created or crosses category, but any override is allowed.

  A **sub-lane is a child stage**: `parent_id` set, `type in [:review, :done]`. `ai_enabled`
  ("Relay AI listens here") is only meaningful for `:work`/`:planning` stages and is forced
  `false` for every other type. `board_id`/`parent_id` are set programmatically, never cast.
  `wip_limit` is the optional MMF 11 limit (`nil` = no limit). `collapsed_by_default`
  (RLY-111) makes the stage start as its 44px strip regardless of card count and applies to
  any stage type.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @types [:queue, :work, :planning, :review, :done]

  schema "stages" do
    field :name, :string
    field :description, :string
    field :position, :integer
    field :category, Ecto.Enum, values: [:unstarted, :planning, :in_progress, :complete]
    field :type, Ecto.Enum, values: @types
    field :ai_enabled, :boolean, default: false
    field :wip_limit, :integer
    field :collapsed_by_default, :boolean, default: false

    belongs_to :board, Schemas.Board
    belongs_to :parent, Schemas.Stage
    belongs_to :reject_to_stage, Schemas.Stage
    has_many :sublanes, Schemas.Stage, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for stage attributes. `board_id`/`parent_id` must already be set on the struct."
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :name,
      :description,
      :position,
      :category,
      :type,
      :ai_enabled,
      :wip_limit,
      :collapsed_by_default,
      :reject_to_stage_id
    ])
    |> validate_required([:name, :position, :category, :type])
    |> validate_number(:wip_limit, greater_than: 0)
    |> normalize_ai_enabled()
    |> validate_child_type()
    |> unique_constraint(:position, name: :stages_board_id_position_index)
    |> unique_constraint(:type, name: :stages_parent_type_index)
  end

  @doc "The type suggested by a category — the default a new/crossed stage takes."
  def default_type(:unstarted), do: :queue
  def default_type(:planning), do: :planning
  def default_type(:in_progress), do: :work
  def default_type(:complete), do: :done

  @doc "The status a card takes when it enters a stage of this type (ADR 0003 + RLY-48)."
  def default_status(:queue), do: :ready
  def default_status(:work), do: :working
  def default_status(:planning), do: :working
  def default_status(:review), do: :in_review
  def default_status(:done), do: :ready

  @doc "Whether `status` is valid for a stage of `type` (RLY-48 validity matrix; RLY-133 adds :queued)."
  def valid_status?(status, :queue), do: status in [:ready, :queued]
  def valid_status?(status, type) when type in [:work, :planning], do: status in [:working, :ready, :needs_input, :failed]
  def valid_status?(status, :review), do: status == :in_review
  def valid_status?(status, :done), do: status in [:ready, :queued]

  @doc """
  The stage categories whose cards appear on the public board (RLY-69) — every
  non-`:complete` band. The single source of truth for "shown publicly"; the
  public-board query and its tests both call this (AGENTS.md magic-value rule).
  """
  def public_categories, do: [:unstarted, :planning, :in_progress]

  # ai_enabled only applies to work/planning; every other type zeroes it (create + type change).
  defp normalize_ai_enabled(changeset) do
    if get_field(changeset, :type) in [:work, :planning] do
      changeset
    else
      put_change(changeset, :ai_enabled, false)
    end
  end

  # A child stage (parent_id set) must be a review or done sub-lane.
  defp validate_child_type(changeset) do
    if get_field(changeset, :parent_id) != nil and get_field(changeset, :type) not in [:review, :done] do
      add_error(changeset, :type, "sub-lane stages must be review or done")
    else
      changeset
    end
  end
end
