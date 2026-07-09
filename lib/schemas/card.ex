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
  `description`/`plan`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "cards" do
    field :title, :string
    field :description, :string
    field :spec, :string
    field :position, :integer
    field :tag, :string
    field :ref_number, :integer

    field :status, Ecto.Enum,
      values: [:queued, :working, :needs_input, :in_review, :done],
      default: :queued

    field :progress, :integer
    field :blocked_since, :utc_datetime
    field :branch, :string
    field :plan, :string
    field :pr_url, :string

    belongs_to :board, Schemas.Board
    belongs_to :stage, Schemas.Stage
    has_many :owners, Schemas.CardOwner

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user/agent-supplied card attributes (`:title`,
  `:description`, `:spec`, `:tag`, `:branch`, `:plan`, `:pr_url`). `board_id`,
  `stage_id`, `position`, and `ref_number` must already be set on the struct
  and are never cast.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :description, :spec, :tag, :branch, :plan, :pr_url])
    |> validate_required([:title])
    |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
  end

  @doc """
  Changeset for the card's baton state: `:status` (enum) and `:progress`
  (0–100, nullable — just stored and displayed; MMF 06 has no automation).
  Kept separate from `changeset/2` so title/description edits can never
  touch the baton and vice versa. Also manages `:blocked_since` (MMF 14)
  bookkeeping: stamped when the status changes to `:needs_input`, cleared
  when it changes to anything else, untouched otherwise — never cast from
  input.
  """
  def status_changeset(card, attrs) do
    card
    |> cast(attrs, [:status, :progress])
    |> validate_required([:status])
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> manage_blocked_since()
  end

  # `blocked_since` tracks how long the card has been waiting on a human
  # (MMF 14): stamped when the status *changes to* :needs_input, cleared
  # when it changes to anything else, untouched when the status isn't
  # changing (e.g. a progress-only update while blocked). Every status
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
end
