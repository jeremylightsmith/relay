defmodule Schemas.Flow.Node do
  @moduledoc """
  One node of a flow's embedded graph (ADR 0006). `type` is the closed
  behavior set; `run` is the node's command/prompt (skill invocation, shell
  line, or agent prompt — `{ref}`/`{branch}`/`{relay}` placeholders are the
  executor's to expand). `model`/`effort` nil means inherit the executor
  default. `human`/`parallel` carry no type-specific attrs yet (nothing
  executes before card 02).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :key, :string
    field :type, Ecto.Enum, values: [:agent, :shell, :gate, :parallel, :human]
    field :run, :string
    field :model, :string
    field :effort, :string
    field :max_retries, :integer
    field :timeout_minutes, :integer
  end

  @doc "Validates one node; graph-level rules (key uniqueness) live on Schemas.Flow."
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:key, :type, :run, :model, :effort, :max_retries, :timeout_minutes])
    |> validate_required([:key, :type])
    |> validate_exclusion(:key, ["start", "done"], message: "is a reserved sentinel name")
    |> validate_number(:max_retries, greater_than: 0)
    |> validate_number(:timeout_minutes, greater_than: 0)
  end
end
