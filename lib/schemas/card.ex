defmodule Schemas.Card do
  @moduledoc """
  A card on a board: a titled unit of work living in one stage. `position`
  orders cards within their stage; `ref_number` is the per-board sequence
  behind the human-facing ref (board key + number, e.g. RL12 — see
  `Relay.Cards.ref/2`). `board_id`, `stage_id`, `position`, and
  `ref_number` are set programmatically, never cast from input. `branch`
  and `plan` (MMF spec 2026-07-08) carry the runner's git branch and
  implementation plan with the card; both nullable, both cast like
  `description`. `pr_url` carries the runner's pull request link with the
  card; nullable, cast like `branch`/`plan`. `spec` (RLY-3) carries the
  design spec authored at the SPEC stage — nullable, cast like
  `description`/`plan`. `acceptance_criteria` (RLY-108) carries the
  numbered acceptance-criteria contract authored at the SPEC stage and run
  by the Code stage's acceptance-tester — nullable, cast like `spec`.
  `archived_at` (RLY-4) soft-hides the card from the
  board; nullable, never cast — set programmatically like `archived_at` on
  boards. `ai_result` (RLY-18) carries the agent's structured result blob
  (summary/changes/screens/deploy_url), nullable, cast like `spec`;
  `sub_tasks` is the card's ordered checklist (RLY-18), written via
  `Relay.Cards.set_sub_tasks/2`, never cast here. `public_description`
  (RLY-69) is the optional public-board copy, distinct from the internal
  `description`; nullable, cast like `description`. `posted_by_user_id`
  (RLY-225) records the public poster of an idea; nullable, never cast —
  set programmatically on the public-posting path only.

  `story_activity_id` / `story_task_id` / `release_id` (RE265) place the card on the story
  map — all three nilable, all three cast **only** through `story_map_changeset/2`, kept
  separate from `changeset/2` and `status_changeset/2` the way the baton is, so a title edit
  can never touch the map and a map edit can never touch the title. Cards start fully
  UNMAPPED.
  `story_map_position` (RE262) orders the card *within* its cell and is independent of
  `position`, which orders it within its stage column — the two never affect each other.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "cards" do
    field :title, :string
    field :description, :string
    field :acceptance_criteria, :string
    field :spec, :string
    field :position, :integer
    # RE262 — the card's order within its story-map CELL, wholly independent of `position` (its
    # order within its stage column). Dragging on the map rewrites this one only; dragging on
    # the board rewrites `position` only. nil = unordered on the map, and nils sort last.
    field :story_map_position, :integer
    field :tag, :string
    field :ref_number, :integer

    field :status, Ecto.Enum,
      values: [:ready, :working, :needs_input, :in_review, :queued, :failed],
      default: :ready

    field :blocked_since, :utc_datetime
    field :agent_heartbeat_at, :utc_datetime
    field :archived_at, :utc_datetime
    field :branch, :string
    field :plan, :string
    field :pr_url, :string
    field :ai_result, :map
    field :public_description, :string

    belongs_to :board, Schemas.Board
    belongs_to :stage, Schemas.Stage
    belongs_to :posted_by_user, Schemas.User
    belongs_to :story_activity, Schemas.StoryActivity
    belongs_to :story_task, Schemas.StoryTask
    belongs_to :release, Schemas.Release
    has_many :owners, Schemas.CardOwner
    has_many :sub_tasks, Schemas.SubTask
    embeds_one :rejection, Schemas.CardRejection, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user/agent-supplied card attributes (`:title`,
  `:description`, `:public_description`, `:acceptance_criteria`, `:spec`,
  `:tag`, `:branch`, `:plan`, `:pr_url`, `:ai_result`). `board_id`,
  `stage_id`, `position`, and `ref_number` must already be set on the
  struct and are never cast.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :title,
      :description,
      :public_description,
      :acceptance_criteria,
      :spec,
      :tag,
      :branch,
      :plan,
      :pr_url,
      :ai_result
    ])
    |> normalize_tag()
    |> validate_required([:title])
    |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
  end

  # "#infra " saves as "infra"; "", "#", and whitespace-only clear to nil. Runs on
  # every write path (drawer, REST PATCH, CLI) so the stored value is always bare.
  defp normalize_tag(changeset) do
    case get_change(changeset, :tag) do
      nil ->
        changeset

      value ->
        normalized = value |> String.trim() |> String.replace_prefix("#", "") |> String.trim()
        put_change(changeset, :tag, if(normalized == "", do: nil, else: normalized))
    end
  end

  @doc """
  Changeset for the card's baton state: `:status` (enum) only. Progress is
  derived from sub-tasks (`Cards.sub_task_progress/1`), never stored on
  the card (RLY-37). Kept separate from `changeset/2` so title/description
  edits can never touch the baton and vice versa. Also manages
  `:blocked_since` (MMF 14) bookkeeping: stamped when the status changes
  to `:needs_input`, cleared when it changes to anything else, untouched
  otherwise — never cast from input.
  """
  def status_changeset(card, attrs) do
    card
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> manage_blocked_since()
  end

  # `blocked_since` tracks how long the card has been waiting on a human
  # (MMF 14): stamped when the status *changes to* :needs_input, cleared
  # when it changes to anything else, untouched when the status isn't
  # changing (e.g. a same-status re-set while blocked). Every status
  # path — drawer control, API, approve/reject, request/answer — goes
  # through this changeset, so the invariant holds everywhere. Never cast
  # from user input.
  defp manage_blocked_since(changeset) do
    case fetch_change(changeset, :status) do
      {:ok, :needs_input} ->
        put_change(changeset, :blocked_since, DateTime.truncate(DateTime.utc_now(), :second))

      {:ok, _other} ->
        put_change(changeset, :blocked_since, nil)

      :error ->
        changeset
    end
  end

  @doc """
  Changeset for the card's story-map placement (RE265): `:story_activity_id`,
  `:story_task_id`, `:release_id`, and (RE262) `:story_map_position`. All four are nilable and
  cast **only** here — never by `changeset/2` or `status_changeset/2`. This is the single cast
  path for everything story-map on a card.

  Enforces the one invariant: **if `story_task_id` is set, `story_activity_id` is set**. The
  matching *value* is derived — `Relay.StoryMap.assign_card/2` reads the activity off the task
  itself — so this guard exists to stop the direct-changeset path producing a half-state.
  `release_id` is deliberately independent: a card can be mapped to a cell with no release.
  """
  def story_map_changeset(card, attrs) do
    card
    |> cast(attrs, [:story_activity_id, :story_task_id, :release_id, :story_map_position])
    |> validate_task_has_activity()
    |> foreign_key_constraint(:story_activity_id)
    |> foreign_key_constraint(:story_task_id)
    |> foreign_key_constraint(:release_id)
  end

  defp validate_task_has_activity(changeset) do
    if get_field(changeset, :story_task_id) && is_nil(get_field(changeset, :story_activity_id)) do
      add_error(changeset, :story_activity_id, "is required when a story task is set")
    else
      changeset
    end
  end

  @doc "True when the card has been archived (soft-hidden from the board)."
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true

  @doc "The closed set of card statuses — the one definition; the docs generate from it (RE239)."
  def statuses, do: Ecto.Enum.values(__MODULE__, :status)

  @doc """
  The closed set of card fields a flow node may declare in its `reads`/`writes` contract
  (RE244) — the ONE definition; `Schemas.Flow.Node`'s two contract enums are its only
  consumers. `commits` is deliberately absent: "this node must produce commits" is
  `Schemas.Flow.Node.expects_commits`, a separate field with a separate guard (RLY-194).
  """
  def contract_fields do
    [:description, :spec, :acceptance_criteria, :plan, :sub_tasks, :branch, :pr_url, :ai_result]
  end
end
