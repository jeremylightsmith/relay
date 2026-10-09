defmodule Schemas.Stage do
  @moduledoc """
  A column on a board. `category` is the board's meaning band (unstarted → planning →
  in_progress → complete). `type` is the stage's **behavior** — one of
  `:queue | :work | :planning | :review | :done` — and drives gates, AI participation, and
  the default card state on entry (see ADR 0003). `category` suggests a default `type`
  (`default_type/1`) when a stage is created or crosses category, but any override is allowed.

  A **sub-lane is a child stage**: `parent_id` set, `type in sublane_types/0`. "AI-enabled" is
  not a stage field — it is derived from flows: a stage is AI-enabled iff a flow works in it
  (`Relay.Flows.ai_stage_ids/1`, RE409). `board_id`/`parent_id` are set programmatically, never cast.
  `wip_limit` is the optional MMF 11 limit (`nil` = no limit). `collapsed_by_default`
  (RLY-111) makes the stage start as its 44px strip regardless of card count and applies to
  any stage type.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @types [:queue, :work, :planning, :review, :done]
  @work_types [:work, :planning]
  @sublane_types [:review, :done]

  schema "stages" do
    field :name, :string
    field :description, :string
    field :position, :integer
    field :category, Ecto.Enum, values: [:unstarted, :planning, :in_progress, :complete]
    field :type, Ecto.Enum, values: @types
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
      :wip_limit,
      :collapsed_by_default,
      :reject_to_stage_id
    ])
    |> validate_required([:name, :position, :category, :type])
    |> validate_number(:wip_limit, greater_than: 0)
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

  @doc """
  The stage types where work happens — the types the claim rule and `Relay.ValueStream` treat
  as work (a `:flow` state, RE146). Defined once.
  """
  def work_types, do: @work_types

  @doc "Guard form of `work_types/0`: `type` is a work-stage type. For clauses that can't call a function."
  defguard is_work_type(type) when type in @work_types

  @doc "Whether `status` is valid for a stage of `type` (RLY-48 validity matrix; RLY-133 adds :queued)."
  def valid_status?(status, :queue), do: status in [:ready, :queued]
  def valid_status?(status, type) when is_work_type(type), do: status in [:working, :ready, :needs_input, :failed]
  def valid_status?(status, :review), do: status == :in_review
  def valid_status?(status, :done), do: status in [:ready, :queued]

  @doc """
  The status a card holding `status` ends up in on arriving at a stage of `type` (ADR 0003):
  `status` itself when `valid_status?/2` allows it there, otherwise `default_status/1`. The single
  arrival rule — create, move, PATCH and stage-type changes all go through it.
  """
  def arrival_status(status, type), do: if(valid_status?(status, type), do: status, else: default_status(type))

  @doc """
  The stage categories whose cards appear on the public board (RLY-69) — every
  non-`:complete` band. The single source of truth for "shown publicly"; the
  public-board query and its tests both call this (AGENTS.md magic-value rule).
  """
  def public_categories, do: [:unstarted, :planning, :in_progress]

  @doc """
  The stage `type`s that mean a card has left every flow's scope — the single source of truth
  for "terminal stage" (RLY-233). The orphaned-run sweep (`Relay.Runs.close_orphaned_runs/0`)
  and the card-event Listener's leak-close rule both filter through this (a run is also a leak
  when its card is archived, RE335); no second literal `:done` partition exists.
  """
  def terminal_types, do: [:done]

  @doc "The closed set of stage categories."
  def categories, do: Ecto.Enum.values(__MODULE__, :category)

  @doc "The closed set of stage types."
  def types, do: Ecto.Enum.values(__MODULE__, :type)

  @doc """
  The stage types a sub-lane (child stage) may have, in display order — Review before Done
  (RE385). The single definition of the sub-lane closed set and its order; `sublane_rank/1`,
  `Relay.Boards`' lane guards and every substage sort derive from it.
  """
  @spec sublane_types() :: [:review | :done]
  def sublane_types, do: @sublane_types

  @doc """
  A sub-lane type's position in `sublane_types/0` (`:review` → 0, `:done` → 1). Any other type
  ranks after every sub-lane type, so a stray/legacy child sorts last rather than raising.
  """
  @spec sublane_rank(atom()) :: non_neg_integer()
  def sublane_rank(type) do
    Enum.find_index(@sublane_types, &(&1 == type)) || length(@sublane_types)
  end

  @doc """
  The word a sub-lane of `type` adds to its main stage's name — `"Code · Done"`, `"Code:Done"`.
  The one definition: `Relay.Boards`' display and composite names and `Relay.Flows.Shape`'s
  column names all build on it.
  """
  @spec lane_word(:review | :done) :: String.t()
  def lane_word(:review), do: "Review"
  def lane_word(:done), do: "Done"

  @doc """
  Orders an in-memory stage list hierarchically: main stages (`parent_id == nil`) by
  `position`, each immediately followed by its substages in `sublane_rank/1` order
  (Review before Done). Children whose parent is not in the list are appended at the end
  by `position`, so nothing is dropped. Pure — no Repo access. Works on any struct or map
  with `:id`, `:parent_id`, `:position` and `:type`.

  The ONE board-order rule: `Relay.Boards.order_stages/1` delegates here, and
  `Relay.Flows.neighbours/2` reads a list in this order.
  """
  @spec order_stages([t() | map()]) :: [t() | map()]
  def order_stages(stages) when is_list(stages) do
    {mains, children} = Enum.split_with(stages, &is_nil(&1.parent_id))
    mains = Enum.sort_by(mains, & &1.position)
    main_ids = MapSet.new(mains, & &1.id)
    {nested, orphans} = Enum.split_with(children, &MapSet.member?(main_ids, &1.parent_id))
    by_parent = Enum.group_by(nested, & &1.parent_id)

    Enum.flat_map(mains, fn main ->
      [main | by_parent |> Map.get(main.id, []) |> Enum.sort_by(&{sublane_rank(&1.type), &1.position})]
    end) ++ Enum.sort_by(orphans, & &1.position)
  end

  # A child stage (parent_id set) must be a review or done sub-lane.
  defp validate_child_type(changeset) do
    if get_field(changeset, :parent_id) != nil and get_field(changeset, :type) not in @sublane_types do
      add_error(changeset, :type, "sub-lane stages must be review or done")
    else
      changeset
    end
  end
end
