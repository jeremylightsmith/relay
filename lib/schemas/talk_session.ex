defmodule Schemas.TalkSession do
  @moduledoc """
  One Talk session per card (ADR 0009). `claude_session_id` is the durable half of the
  conversation — the executor holds the actual session on its own disk, the server holds only
  the id, and passing it as `--resume` is what makes turn *n+1* a continuation. It is nil until
  the first turn FINISHES, so a stopped or failed first turn correctly starts fresh rather than
  resuming a session that may not exist.

  `pinned_executor_name` is the machine holding that session; every later turn is offered only
  to it (`Relay.Talk.post_message/3` copies it onto the job row, exactly as an exclusive run's
  pin rides on `node_jobs.executor_name`).

  `last_event_seq` is the session's monotonic render-order counter; `cleared_through_seq` is
  how `/clear` HIDES scrollback — nothing is ever deleted.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "talk_sessions" do
    field :claude_session_id, :string
    field :pinned_executor_name, :string
    field :seed_summary, :string
    field :seed_fields, {:array, :map}, default: []
    field :last_event_seq, :integer, default: 0
    field :cleared_through_seq, :integer, default: 0

    belongs_to :card, Schemas.Card

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built session row. All fields are programmatic — nothing here is ever cast from user input."
  def changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, [:claude_session_id, :pinned_executor_name, :seed_summary, :seed_fields, :cleared_through_seq])
    |> validate_required([:card_id])
    |> unique_constraint(:card_id)
    |> foreign_key_constraint(:card_id)
  end
end
