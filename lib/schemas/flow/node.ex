defmodule Schemas.Flow.Node do
  @moduledoc """
  One node of a flow's embedded graph (ADR 0006). `type` is the closed
  behavior set; `run` is the node's command/prompt (skill invocation, shell
  line, or agent prompt — `{ref}`/`{branch}`/`{relay}` placeholders are the
  runner's to expand). `llm` (RE433) names one of the board's agents
  (`Schemas.Agent`, a harness + model) and nil means inherit the board's
  default agent; `effort` nil means inherit the harness default. `human` carries no
  type-specific attrs yet.

  ## Control nodes (RE437)

  `fan_out` and `fan_in` (`control_types/0`) are **control nodes**: the server resolves them and
  no runner job ever runs them, so they may carry none of `work_fields/0`. A `fan_out` fires
  every outgoing edge at once (its edges carry no `on`), each edge starting a **branch**; the
  paired `fan_in` waits for every branch. `max_parallel` (`fan_out` only, nil = every branch at
  once) caps how many branches run together. Pairing and every region rule live on
  `Schemas.Flow` (`regions/1`).

  `foreach` (nil = not a loop head) makes the node a `foreach` LOOP HEAD:
  each entry into it begins one iteration bound to one of the card's
  tasks. `foreach_sources/0` (`"card.tasks"`) is the only accepted source. Nodes inside the
  loop name the bound task with the `{task}` (title) and `{task_id}` (id) placeholders.

  `tasks` / `card.tasks` / `{task}` / `{task_id}` / `llm` / `fan_out` are the only spellings: a
  renamed one (`sub_tasks`, `model`, `parallel`, …) is never rewritten (RE487) —
  `Hamaca.Flows.Document.decode/1` refuses it, naming the rename.

  `agent` (agent nodes only) names a `.claude/agents/<name>.md` definition: the
  runner appends `--agent <name>` to its `claude -p` call, so the file supplies
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

  `role` (RE346, nil = guess) is the node's place in the value stream — `:do` changes the work,
  `:check` inspects it, `:fix` exists only because a check failed. It is valid on **every** node
  type and any value is legal anywhere: an authored role **always wins**, and
  `Schemas.Flow.node_roles/1` guesses only an unset one (all-`:failed` inbound edges → `:fix`,
  a `:gate` → `:check`, otherwise `:do`). Check vs do can't be fully guessed — `sync`, `resync`
  and `merge` have outbound `:failed` edges yet change the work — so agent and shell checks author
  `role: :check`. **Display-only**: the engine and the runner never branch on it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @fields [
    :key,
    :type,
    :run,
    :llm,
    :effort,
    :max_retries,
    :timeout_minutes,
    :foreach,
    :agent,
    :expects_commits,
    :reads,
    :writes,
    :role,
    :max_parallel
  ]
  @types [:agent, :shell, :gate, :fan_out, :fan_in, :human]
  @control_types [:fan_out, :fan_in]
  @work_fields [:run, :agent, :llm, :effort, :max_retries, :timeout_minutes]
  @roles [:do, :check, :fix]
  @foreach_sources ["card.tasks"]

  @primary_key false
  embedded_schema do
    field :key, :string
    field :type, Ecto.Enum, values: @types
    field :run, :string
    field :llm, :string
    field :effort, :string
    field :max_retries, :integer
    field :timeout_minutes, :integer
    field :foreach, :string
    field :agent, :string
    field :expects_commits, :boolean, default: false
    field :reads, {:array, Ecto.Enum}, values: Schemas.Card.contract_fields(), default: []
    field :writes, {:array, Ecto.Enum}, values: Schemas.Card.contract_fields(), default: []
    field :role, Ecto.Enum, values: @roles
    field :max_parallel, :integer
  end

  @doc """
  The closed set of node fields — the ONE list every consumer reads (this schema's `cast/3`,
  `Hamaca.Flows`' normalize/snapshot/duplicate, the flow editor's working copy, and
  `Hamaca.Flows.Document`). Copies of it disagreed before RLY-241 and silently dropped
  `expects_commits`.
  """
  def fields, do: @fields

  @doc "The closed set of node `type` values (read by the schema field and by the decoder)."
  def types, do: @types

  @doc """
  The closed set of node `role` values (RE346) — Do changes the work, Check inspects it, Fix exists
  only because a check failed. Read by the schema field, by `Hamaca.Flows.Document`'s decoder and by
  `Schemas.Flow.node_roles/1`'s callers; never re-typed elsewhere.
  """
  def roles, do: @roles

  @doc ~S"""
  The subset of node `type`s a runner actually runs (RLY-139). A strict subset of `types/0` —
  `:fan_out`, `:fan_in` and `:human` are valid node types that do not dispatch — so this is
  guarded as a subset, not a partition.
  """
  def runnable_types, do: [:agent, :shell, :gate]

  @doc ~S"""
  The control node types (RE437) — resolved on the server, never a runner job. The ONE copy of
  that set: validation, the engine and the UI all read it from here.
  """
  @spec control_types() :: [:fan_out | :fan_in]
  def control_types, do: @control_types

  @doc """
  The fields that describe work a runner does (RE437), in message order — a control node
  (`control_types/0`) may carry none of them.
  """
  @spec work_fields() :: [atom()]
  def work_fields, do: @work_fields

  @doc """
  RE444 — true for an **inline prompt**: an `:agent` node with no subagent (`agent` nil or `""`),
  so its `run` text is the whole prompt (the template flows' "no skills" shape). The ONE copy of
  that predicate: the flow editor's "inline · no skill" tag and the example board's node panel
  both read it. Takes a struct or a plain map (read via `Map.get/2`).
  """
  @spec inline_prompt?(map()) :: boolean()
  def inline_prompt?(node) when is_map(node), do: Map.get(node, :type) == :agent and Map.get(node, :agent) in [nil, ""]

  @doc "The closed set of accepted `foreach` sources (RE367: `\"card.tasks\"`). Read by `changeset/2` and the docs."
  def foreach_sources, do: @foreach_sources

  @doc "Validates one node; graph-level rules (key uniqueness) live on Schemas.Flow."
  def changeset(node, attrs) do
    node
    |> cast(attrs, @fields)
    |> validate_required([:key, :type])
    |> validate_exclusion(:key, ["start", "done", "needs_input"], message: "is a reserved sentinel name")
    |> validate_number(:max_retries, greater_than: 0)
    |> validate_number(:timeout_minutes, greater_than: 0)
    |> validate_inclusion(:foreach, @foreach_sources,
      message: "must be #{Enum.map_join(@foreach_sources, " or ", &inspect/1)}"
    )
    |> validate_agent_only_on_agent_nodes()
    |> validate_llm_only_on_agent_nodes()
    |> validate_expects_commits_only_on_agent_nodes()
  end

  # `agent` names a `.claude/agents/<name>.md` definition the runner passes to
  # `claude -p --agent`. It is meaningless on a shell/gate/human node, so say so
  # loudly rather than silently ignoring it.
  # A control node hears it once, from `Schemas.Flow`'s "does no work" rule, not twice.
  defp validate_agent_only_on_agent_nodes(changeset) do
    if get_field(changeset, :agent) && get_field(changeset, :type) not in [:agent | @control_types] do
      add_error(changeset, :agent, "is only valid on an agent node")
    else
      changeset
    end
  end

  # RE433: `llm` picks the agent an agent node runs on; nothing else runs an LLM.
  defp validate_llm_only_on_agent_nodes(changeset) do
    if get_field(changeset, :llm) && get_field(changeset, :type) not in [:agent | @control_types] do
      add_error(changeset, :llm, "is only valid on an agent node")
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
