defmodule Schemas.Flow.Node do
  @moduledoc """
  One node of a flow's embedded graph (ADR 0006). `type` is the closed
  behavior set; `run` is the node's command/prompt (skill invocation, shell
  line, or agent prompt — `{ref}`/`{branch}`/`{relay}` placeholders are the
  executor's to expand). `model`/`effort` nil means inherit the executor
  default. `human`/`parallel` carry no type-specific attrs yet (nothing
  executes before card 02).

  `foreach` (nil = not a loop head) makes the node a `foreach` LOOP HEAD:
  each entry into it begins one iteration bound to one of the card's
  sub_tasks. `"card.sub_tasks"` is the only source W13 accepts.

  `agent` (agent nodes only) names a `.claude/agents/<name>.md` definition: the
  executor appends `--agent <name>` to its `claude -p` call, so the file supplies
  the system prompt while `run` stays the user prompt. nil = today's invocation.

  `expects_commits` (agent nodes only, default `false`, RLY-194) marks a node
  that must produce commits to do its work — `RunServer` may override a
  reported `:succeeded` back to `:failed` when HEAD didn't move. `"needs_input"`
  is reserved alongside `"start"`/`"done"` as an edge-endpoint sentinel, so no
  node may be keyed with it.
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
    field :foreach, :string
    field :agent, :string
    field :expects_commits, :boolean, default: false
  end

  @doc ~S"""
  The subset of node `type`s an executor actually runs (RLY-139). A strict subset of the type
  enum — `:parallel` and `:human` are valid node types that do not dispatch — so this is
  guarded as a subset, not a partition.
  """
  def runnable_types, do: [:agent, :shell, :gate]

  @doc "Validates one node; graph-level rules (key uniqueness) live on Schemas.Flow."
  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :key,
      :type,
      :run,
      :model,
      :effort,
      :max_retries,
      :timeout_minutes,
      :foreach,
      :agent,
      :expects_commits
    ])
    |> validate_required([:key, :type])
    |> validate_exclusion(:key, ["start", "done", "needs_input"], message: "is a reserved sentinel name")
    |> validate_number(:max_retries, greater_than: 0)
    |> validate_number(:timeout_minutes, greater_than: 0)
    |> validate_inclusion(:foreach, ["card.sub_tasks"], message: ~s(must be "card.sub_tasks"))
    |> validate_agent_only_on_agent_nodes()
    |> validate_expects_commits_only_on_agent_nodes()
  end

  # `agent` names a `.claude/agents/<name>.md` definition the executor passes to
  # `claude -p --agent`. It is meaningless on a shell/gate/human node, so say so
  # loudly rather than silently ignoring it.
  defp validate_agent_only_on_agent_nodes(changeset) do
    if get_field(changeset, :agent) && get_field(changeset, :type) != :agent do
      add_error(changeset, :agent, "is only valid on an agent node")
    else
      changeset
    end
  end

  # RLY-194: expects_commits means "the server may override this node's success if it
  # produced no commits". That only makes sense on an agent node — a shell/gate node
  # marked expects_commits is a definition error, not a silent no-op.
  defp validate_expects_commits_only_on_agent_nodes(changeset) do
    if get_field(changeset, :expects_commits) && get_field(changeset, :type) != :agent do
      add_error(changeset, :expects_commits, "is only valid on an agent node")
    else
      changeset
    end
  end
end
