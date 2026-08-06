defmodule Schemas.TalkEvent do
  @moduledoc """
  One rendered line of the transcript, append-only (ADR 0009). `seq` is server-assigned and
  monotonic per session — **render order is this, never a timestamp**, because two lines
  written in the same second must still have one true order.

  `client_seq` is the executor's own per-turn counter, unique with `talk_turn_id`. That
  uniqueness is the whole at-least-once story: the executor may re-POST a batch it is unsure
  landed, and the retry stores exactly once.

  `dim` is presentation only (the artboard's dim tool lines); it is never authority.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "talk_events" do
    field :seq, :integer
    field :client_seq, :integer
    field :kind, Ecto.Enum, values: [:user, :tool, :out, :error]
    field :text, :string
    field :dim, :boolean, default: false

    belongs_to :talk_session, Schemas.TalkSession
    belongs_to :talk_turn, Schemas.TalkTurn

    timestamps(type: :utc_datetime)
  end

  @doc "The closed set of transcript line kinds. `:act` (receipts) belongs to step 2 and is deliberately absent."
  def kinds, do: Ecto.Enum.values(__MODULE__, :kind)

  @doc "Validates a programmatically-built event row."
  def changeset(event, attrs \\ %{}) do
    event
    |> cast(attrs, [:kind, :text, :dim, :client_seq])
    |> validate_required([:talk_session_id, :talk_turn_id, :seq, :client_seq, :kind, :text])
    |> unique_constraint([:talk_turn_id, :client_seq])
  end
end
