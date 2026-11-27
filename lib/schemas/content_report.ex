defmodule Schemas.ContentReport do
  @moduledoc """
  One person's report of one item (RE510): a public-board idea (`card_id`) or a member's comment
  (`comment_id`) — exactly one of the two, enforced by a check constraint. A person reports an
  item at most once (two partial unique indexes).

  Only `reason` and `note` are cast. The reporter and target are set on the struct by
  `Hamaca.Moderation.report/3`; the resolution fields (`resolution`, `resolved_by_id`,
  `resolved_at`, `prior_hidden_reason`, `suspended_user_id`) are written only by the admin
  actions. Reports resolved by one action share `resolved_at` — that, with the target and the
  resolution, is the batch `Hamaca.Moderation.undo/2` reverses.

  This module owns the moderation vocabularies: `reasons/0`, `resolutions/0` and
  `hidden_reasons/0` (the values `Schemas.Card` and `Schemas.Comment` type `hidden_reason` with).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @reasons [:spam, :harassment, :sexual_violent, :other]
  @resolutions [:dismissed, :hidden, :suspended]
  @hidden_reasons [:auto_reports, :admin]
  @note_max_length 1000

  schema "content_reports" do
    field :reason, Ecto.Enum, values: @reasons
    field :note, :string
    field :resolution, Ecto.Enum, values: @resolutions
    field :resolved_at, :utc_datetime
    field :prior_hidden_reason, Ecto.Enum, values: @hidden_reasons

    belongs_to :reporter, Schemas.User
    belongs_to :card, Schemas.Card
    belongs_to :comment, Schemas.Comment
    belongs_to :resolved_by, Schemas.User
    belongs_to :suspended_user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc "Why a person reports an item, in the order the report modal lists them."
  @spec reasons() :: [:spam | :harassment | :sexual_violent | :other]
  def reasons, do: @reasons

  @doc "The label a person reads for a reason."
  @spec reason_label(atom()) :: String.t()
  def reason_label(:spam), do: "Spam"
  def reason_label(:harassment), do: "Harassment or hate"
  def reason_label(:sexual_violent), do: "Sexual or violent"
  def reason_label(:other), do: "Something else"

  @doc "How an admin resolved a report."
  @spec resolutions() :: [:dismissed | :hidden | :suspended]
  def resolutions, do: @resolutions

  @doc "The label an admin reads for a resolution."
  @spec resolution_label(atom()) :: String.t()
  def resolution_label(:dismissed), do: "Dismissed"
  def resolution_label(:hidden), do: "Hidden"
  def resolution_label(:suspended), do: "Suspended"

  @doc """
  Why an item is hidden for everyone: `:auto_reports` (enough distinct reports) or `:admin` (an
  admin's Hide or Suspend). The ONE list `Schemas.Card` and `Schemas.Comment` type
  `hidden_reason` with.
  """
  @spec hidden_reasons() :: [:auto_reports | :admin]
  def hidden_reasons, do: @hidden_reasons

  @doc "The longest note a report may carry."
  @spec note_max_length() :: 1000
  def note_max_length, do: @note_max_length

  @doc """
  Casts only `:reason` and `:note`. The note is trimmed and a blank one stored as `nil`; the
  reporter and target must already be set on the struct.
  """
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:reason, :note])
    |> update_change(:note, &blank_to_nil/1)
    |> validate_required([:reason])
    |> validate_length(:note, max: @note_max_length)
    |> unique_constraint([:reporter_id, :card_id], name: :content_reports_reporter_card)
    |> unique_constraint([:reporter_id, :comment_id], name: :content_reports_reporter_comment)
    |> check_constraint(:card_id, name: :content_reports_one_target)
  end

  defp blank_to_nil(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
