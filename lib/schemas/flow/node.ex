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

  `reads` / `writes` (RE244) are the node's **card-field contract** — which of
  `Schemas.Card.contract_fields/0` it consumes and which it must fill. Unlike
  `agent`/`expects_commits` these are valid on **every** node type: the Code flow's
  `branch` node is a `shell` node that writes `branch`. `writes` is **enforced at run
  time** — `RunServer` rewrites a reported `:succeeded` to `:failed` when a declared
  field is still blank. `reads` is **advisory only** (doctor-only, never a run-time
  precondition): plenty of legitimate cards carry a title and no description, so a read
  precondition would fail the Spec flow on every one of them. Do not "complete the
  symmetry".
  """

  use Ecto.Schema

  import Ecto.Changeset

  @fields [
    :key,
    :type,
    :run,
    :model,
    :effort,
    :max_retries,
    :timeout_minutes,
    :foreach,
    :agent,
    :expects_commits,
    :reads,
    :writes
  ]
  @types [:agent, :shell, :gate, :parallel, :human]

  @primary_key false
  embedded_schema do
    field :key, :string
    field :type, Ecto.Enum, values: @types
    field :run, :string
    field :model, :string
    field :effort, :string
    field :max_retries, :integer
    field :timeout_minutes, :integer
    field :foreach, :string
    field :agent, :string
    field :expects_commits, :boolean, default: false
    field :reads, {:array, Ecto.Enum}, values: Schemas.Card.contract_fields(), default: []
    field :writes, {:array, Ecto.Enum}, values: Schemas.Card.contract_fields(), default: []
  end

  @doc """
  The closed set of node fields — the ONE list every consumer reads (this schema's `cast/3`,
  `Relay.Flows`' normalize/snapshot/duplicate, the flow editor's working copy, and
  `Relay.Flows.Document`). Copies of it disagreed before RLY-241 and silently dropped
  `expects_commits`.
  """
  def fields, do: @fields

  @doc "The closed set of node `type` values (read by the schema field and by the decoder)."
  def types, do: @types

  @doc ~S"""
  The subset of node `type`s an executor actually runs (RLY-139). A strict subset of `types/0` —
  `:parallel` and `:human` are valid node types that do not dispatch — so this is guarded as a
  subset, not a partition.
  """
  def runnable_types, do: [:agent, :shell, :gate]

  @doc "Validates one node; graph-level rules (key uniqueness) live on Schemas.Flow."
  def changeset(node, attrs) do
    node
    |> cast(attrs, @fields)
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
