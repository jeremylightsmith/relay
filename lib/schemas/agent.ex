defmodule Schemas.Agent do
  @moduledoc """
  A board's named LLM (RE433): a harness plus one of that harness's models. Flow nodes name an
  agent by `name` in their `llm` field; `boards.default_agent_id` is the one a node with no `llm`
  inherits. Not to be confused with a node's `agent` field, which names a `.claude/agents/*.md`
  subagent definition.

  `model` must be in the harness's `models` when the agent is written. A harness edit may later
  drop it — that agent is then **red** (`Relay.Agents.red?/1`) and refuses to run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "agents" do
    field :name, :string
    field :model, :string

    belongs_to :board, Schemas.Board
    belongs_to :harness, Schemas.Harness

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Validates an agent against `harness` — the harness it names after the cast — so the model can
  be checked against that harness's list. `board_id` is set programmatically, never cast.
  """
  def changeset(agent, attrs, %Schemas.Harness{} = harness) do
    agent
    |> cast(attrs, [:name, :harness_id, :model])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :harness_id, :model])
    |> validate_inclusion(:model, harness.models, message: "is not one of #{harness.name}'s models")
    |> unique_constraint(:name, name: :agents_board_id_name_index, message: "is already used on this board")
    |> foreign_key_constraint(:harness_id)
  end
end
