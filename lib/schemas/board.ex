defmodule Schemas.Board do
  @moduledoc """
  A user's kanban board. One board per user for now (MMF 19 adds more).
  `slug` is stored for future slug-routing (MMF 19); `key` is the
  exactly-2-letter card-ref prefix (e.g. "RL12", used from MMF 03,
  dashless since RLY-230). `owner_id` is set programmatically, never cast
  from input. `card_seq` is the per-board card-ref counter (MMF 03),
  bumped under a row lock by `Relay.Cards.create_card/2` and never cast
  from input.
  `public_enabled` + `public_intake_stage_id` (RLY-69) are the public-board
  settings, written only via `public_settings_changeset/2`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "boards" do
    field :name, :string, default: "My board"
    field :slug, :string
    field :key, :string, default: "RL"
    field :card_seq, :integer, default: 0
    field :archived_at, :utc_datetime
    field :public_enabled, :boolean, default: false

    belongs_to :owner, Schemas.User
    belongs_to :public_intake_stage, Schemas.Stage
    has_many :stages, Schemas.Stage

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for board attributes. `owner_id` must already be set on the struct."
  def changeset(board, attrs) do
    board
    # `empty_values: []` disables Ecto's default cast behavior of silently
    # substituting a blank/whitespace param with the field's schema default
    # (`name`'s default is "My board") — without this, submitting a blank
    # name would reset it to "My board" instead of failing validation below.
    |> cast(attrs, [:name, :slug, :key], empty_values: [])
    |> update_change(:name, &String.trim/1)
    |> update_change(:key, &normalize_key/1)
    |> validate_required([:name, :slug, :key])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:key, ~r/\A[A-Z]{2}\z/, message: "must be exactly 2 letters")
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
      message: "must be lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:slug)
  end

  # Upcase, then keep only A–Z. `validate_format/3` above enforces the "exactly 2" rule on the
  # normalized value, so "rl" -> "RL", "R1" -> "R" (rejected), "abc" -> "ABC" (rejected).
  defp normalize_key(key), do: key |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z]/, "")

  @doc """
  Changeset for the RLY-69 public-board settings — the enable toggle and the intake
  stage. Deliberately separate from `changeset/2` (which guards name/slug/key). The
  Boards context validates that the intake stage belongs to this board.
  """
  def public_settings_changeset(board, attrs) do
    cast(board, attrs, [:public_enabled, :public_intake_stage_id])
  end

  @doc "True when the board has been archived (read-only)."
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true
end
