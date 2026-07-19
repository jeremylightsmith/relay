defmodule Schemas.Card do
  @moduledoc """
  A card on a board: a titled unit of work living in one stage. `position`
  orders cards within their stage; `ref_number` is the per-board sequence
  behind the human-facing ref (board key + number, e.g. RLY-12 — see
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
  `Relay.Cards.set_sub_tasks/2`, never cast here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "cards" do
    field :title, :string
    field :description, :string
    field :acceptance_criteria, :string
    field :spec, :string
    field :position, :integer
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

    belongs_to :board, Schemas.Board
    belongs_to :stage, Schemas.Stage
    has_many :owners, Schemas.CardOwner
    has_many :sub_tasks, Schemas.SubTask
    embeds_one :rejection, Schemas.CardRejection, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user/agent-supplied card attributes (`:title`,
  `:description`, `:acceptance_criteria`, `:spec`, `:tag`, `:branch`,
  `:plan`, `:pr_url`, `:ai_result`). `board_id`, `stage_id`, `position`, and
  `ref_number` must already be set on the struct and are never cast.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :title,
      :description,
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

  @doc "True when the card has been archived (soft-hidden from the board)."
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true
end
