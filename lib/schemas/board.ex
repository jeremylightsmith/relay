defmodule Schemas.Board do
  @moduledoc """
  A user's kanban board. One board per user for now (MMF 19 adds more).
  `slug` is stored for future slug-routing (MMF 19); `key` is the
  exactly-2-letter card-ref prefix (e.g. "RL12", used from MMF 03,
  dashless since RLY-230). `owner_id` is set programmatically, never cast
  from input. `card_seq` is the per-board card-ref counter (MMF 03),
  bumped under a row lock by `Hamaca.Cards.create_card/2` and never cast
  from input.
  `public_enabled` + `public_intake_stage_id` (RLY-69) are the public-board
  settings, written only via `public_settings_changeset/2`.
  `story_map_view` (RE257) is the board-wide shared story-map view state, written only via
  `story_map_view_changeset/2` and keyed by `Hamaca.StoryMap.view_defaults/0` — the single
  source of truth for which keys the view holds.
  `default_agent_id` (RE433) is the board's default LLM, written only by `Hamaca.Agents`.
  `example_template` (RE444) marks the board as a template's public example, written only via
  `example_changeset/2`.
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
    field :story_map_view, :map, default: %{}
    # RE444: the template slug this board is the public example of. Written only by
    # `Hamaca.Boards.mark_example/2` via `example_changeset/2`, never cast by `changeset/2`.
    field :example_template, :string

    belongs_to :owner, Schemas.User
    belongs_to :public_intake_stage, Schemas.Stage
    # RE433: the agent a flow node with no `llm` runs on. Written only by
    # `Hamaca.Agents.set_default_agent/2`, never cast by `changeset/2`.
    belongs_to :default_agent, Schemas.Agent
    has_many :stages, Schemas.Stage

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

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
    |> validate_length(:name, min: 1, max: name_max_length())
    |> validate_format(:key, key_format(), message: "must be exactly 2 letters")
    |> validate_format(:slug, slug_format(), message: "must be lowercase letters, numbers, and hyphens")
    |> unique_constraint(:slug)
  end

  @doc "The board slug format — lowercase letters and digits in hyphen-separated runs (RE443: the install route checks it too)."
  @spec slug_format() :: Regex.t()
  def slug_format, do: ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc "The card-ref key format — exactly two upper-case letters (RE455: the New board picker checks it too)."
  @spec key_format() :: Regex.t()
  def key_format, do: ~r/\A[A-Z]{2}\z/

  @doc "The longest board name `changeset/2` accepts (RE455: the New board picker's `maxlength`)."
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: 80

  @doc """
  A card key from a board name: upper-cased, only A–Z kept, the first two. Possibly fewer than
  two letters and never a fallback — `"A1"` -> `"A"`, `"42"` -> `""`, `nil` -> `""`. The New board
  picker (RE455) derives and sanitizes its key with it; `Hamaca.Boards` adds its own "RL" fallback.
  """
  @spec key_from_name(String.t() | nil) :: String.t()
  def key_from_name(name), do: name |> letters_only() |> String.slice(0, 2)

  # Upcase, then keep only A–Z. `validate_format/3` above enforces the "exactly 2" rule on the
  # normalized value, so "rl" -> "RL", "R1" -> "R" (rejected), "abc" -> "ABC" (rejected).
  defp normalize_key(key), do: letters_only(key)

  defp letters_only(value), do: value |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z]/, "")

  @doc """
  Changeset for the RLY-69 public-board settings — the enable toggle and the intake
  stage. Deliberately separate from `changeset/2` (which guards name/slug/key). The
  Boards context validates that the intake stage belongs to this board.
  """
  def public_settings_changeset(board, attrs) do
    cast(board, attrs, [:public_enabled, :public_intake_stage_id])
  end

  @doc """
  Changeset for the RE257 **shared** story-map view settings — the one jsonb column
  `Hamaca.StoryMap.merge_view/2` writes (the writer `put_view/3`, `toggle_view/2` and
  `toggle_view_member/4` all compose). Deliberately separate from `changeset/2` (which guards
  name/slug/key), mirroring `public_settings_changeset/2`. The key set itself is validated by
  `Hamaca.StoryMap.view_defaults/0`, not here: the column is a bag, and the context owns its
  vocabulary.
  """
  def story_map_view_changeset(board, attrs) do
    cast(board, attrs, [:story_map_view])
  end

  @doc """
  Changeset for the RE444 example marking — the one `example_template` column. Deliberately
  separate from `changeset/2`, mirroring `public_settings_changeset/2`. The slug itself is
  validated by `Hamaca.Boards.mark_example/2` against the template list; the unique index
  keeps it to one board per slug.
  """
  def example_changeset(board, attrs) do
    board
    |> cast(attrs, [:example_template])
    |> unique_constraint(:example_template)
  end

  @doc "True when the board has been archived (read-only)."
  def archived?(%__MODULE__{archived_at: nil}), do: false
  def archived?(%__MODULE__{}), do: true
end
