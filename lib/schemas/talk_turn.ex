defmodule Schemas.TalkTurn do
  @moduledoc """
  One human message and the work it caused (ADR 0009 §1). The turn is the unit with a
  lifecycle: `queued` when the person hits Enter, `claimed` when a worker takes it, then
  `done`, `stopped` (the person hit Stop — a normal, NON-error end state whose partial output
  stays in the transcript) or `failed`.

  `awaiting` is deliberately absent in step 1: it is turn state, never card state, and it lands
  with [AC17]. A talk turn must never call `Relay.Cards.request_input/3` — that parks the card
  and blocks its flow.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "talk_turns" do
    field :prompt, :string
    field :status, Ecto.Enum, values: [:queued, :claimed, :done, :stopped, :failed]
    field :detail, :string

    belongs_to :talk_session, Schemas.TalkSession
    belongs_to :author, Schemas.User
    belongs_to :node_job, Schemas.NodeJob

    timestamps(type: :utc_datetime)
  end

  @doc "The closed set of turn statuses."
  def statuses, do: Ecto.Enum.values(__MODULE__, :status)

  @doc "Turn statuses where the turn is still live — the pane shows Stop instead of send, and a second turn is refused."
  def active_statuses, do: [:queued, :claimed]

  @doc "Validates a programmatically-built turn row."
  def changeset(turn, attrs \\ %{}) do
    turn
    |> cast(attrs, [:status, :detail, :node_job_id])
    |> validate_required([:talk_session_id, :prompt, :status])
    |> foreign_key_constraint(:talk_session_id)
  end
end
