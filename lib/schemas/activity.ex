defmodule Schemas.Activity do
  @moduledoc """
  One entry in a card's activity log: what happened (`type`), free-form
  details (`meta`, a jsonb map with STRING keys — e.g.
  `%{"from_stage" => "Spec", "to_stage" => "Code"}`), and who did it —
  a user (`actor_type: :user` + `user_id`) or the Relay AI agent
  (`actor_type: :agent`, no `user_id`). All fields are set
  programmatically by `Relay.Activity.log/2`, never cast from input.
  `:commented` is reserved for future feeds/API use (MMF 09/16) —
  nothing emits it in MMF 07. `:needs_input` (MMF 14) carries
  `meta: %{"question" => ...}` — the AI blocked the card on a human
  question. `:input_answered` (MMF 14) marks the human's answer, with
  empty meta. `:archived` / `:unarchived` (RLY-4) record a card being
  soft-hidden from the board and restored, with empty meta.

  `:action` (RLY-112) is one runner log line, with the line in `text` and the AI
  session that emitted it in `run_id`; `:failure` (RLY-112) is the agent erroring.
  Both are written in bulk by `Relay.Activity.LogSink` via `insert_all`, which
  bypasses `changeset/1` by design — they are best-effort chatter, not audit rows.
  `text`/`run_id` are null on every human/system row. There is deliberately no
  `:heartbeat` type: liveness is `cards.agent_heartbeat_at` (Q3→B).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @types [
    :created,
    :moved,
    :status_changed,
    :owners_changed,
    :commented,
    :approved,
    :rejected,
    :needs_input,
    :input_answered,
    :archived,
    :unarchived,
    :action,
    :failure
  ]

  schema "activities" do
    field :type, Ecto.Enum, values: @types
    field :meta, :map, default: %{}
    field :actor_type, Ecto.Enum, values: [:user, :agent]
    field :text, :string
    field :run_id, :string

    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc "Validates a programmatically-built activity entry."
  def changeset(activity) do
    activity
    |> change()
    |> validate_required([:card_id, :type, :actor_type])
    |> validate_actor_user()
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_actor_user(changeset) do
    case {get_field(changeset, :actor_type), get_field(changeset, :user_id)} do
      {:user, nil} -> add_error(changeset, :user_id, "can't be blank")
      {:agent, user_id} when not is_nil(user_id) -> add_error(changeset, :user_id, "must be empty for the AI agent")
      _other -> changeset
    end
  end
end
