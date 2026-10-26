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

  ## Legacy aliases (RE367)

  `tasks` is the canonical flow-contract name for a card's plan units. The pre-RE367 spellings
  are accepted as **deprecated aliases** and rewritten to canonical by `normalize_legacy/1`,
  which runs wherever a flow enters the system (`changeset/2`, `Hamaca.Flows.Document.decode/1`),
  so a stored or served flow is always canonical:

  | concept | canonical | legacy alias |
  |---|---|---|
  | contract field in `reads` / `writes` | `tasks` | `sub_tasks` |
  | `foreach` source | `card.tasks` | `card.sub_tasks` |
  | `run` placeholder: task title | `{task}` | `{sub_task}` |
  | `run` placeholder: task id | `{task_id}` | `{sub_task_id}` |
  | the node's LLM (RE433) | `llm` (an agent name) | `model` (`legacy_models/0`) |
  | node `type` (RE437) | `fan_out` | `parallel` |

  A legacy `model` **key** is renamed to `llm`, its value mapped through `legacy_models/0`
  (`"opus"` → `"Claude Opus"`); a value outside the table is carried through verbatim so
  `Hamaca.Flows` refuses it loudly as an unknown agent. An explicit `llm` always wins.

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

  # RE367 — legacy spelling → canonical spelling, the ONE copy of the alias table (the data
  # migration that rewrote stored rows carries its own frozen copy, by migration convention).
  @legacy_contract_fields [sub_tasks: :tasks]
  @legacy_foreach_sources %{"card.sub_tasks" => "card.tasks"}
  @legacy_placeholders %{"{sub_task}" => "{task}", "{sub_task_id}" => "{task_id}"}
  # RE433 — the pre-agents `model` value → the agent name every board is seeded with.
  @legacy_models %{"opus" => "Claude Opus", "sonnet" => "Claude Sonnet", "haiku" => "Claude Haiku"}
  # RE437 — the never-run `parallel` type became `fan_out`, keeping the value's type (string or
  # atom). The data migration that rewrote stored rows carries its own frozen copy.
  @legacy_types %{"parallel" => "fan_out", parallel: :fan_out}

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
  RE433 — the legacy node `model` value → the board agent name it became, the ONE copy (the data
  migration carries a frozen duplicate). `Hamaca.Agents.ensure_seeded!/1` seeds one agent per entry.
  """
  @spec legacy_models() :: %{String.t() => String.t()}
  def legacy_models, do: @legacy_models

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

  @doc """
  A node attrs map (string or atom keys, as given) with every legacy alias rewritten to its
  canonical spelling — see the moduledoc's alias table. Canonical input and unrelated text are
  returned unchanged; `run` is rewritten only at the exact-brace placeholder literals. A struct is
  returned as-is (it was already cast).
  """
  def normalize_legacy(%_{} = struct), do: struct

  def normalize_legacy(attrs) when is_map(attrs) do
    attrs
    |> rename_model_to_llm()
    |> Map.new(fn {key, value} -> {key, normalize_attr(to_string(key), value)} end)
  end

  # RE433: `model` → `llm`, keeping the attrs' key type. An explicit `llm` wins over `model`.
  defp rename_model_to_llm(attrs) do
    Enum.reduce([{"model", "llm"}, {:model, :llm}], attrs, fn {model_key, llm_key}, acc ->
      case Map.pop(acc, model_key) do
        {nil, ^acc} -> acc
        {model, rest} -> Map.update(rest, llm_key, legacy_llm(model), &(&1 || legacy_llm(model)))
      end
    end)
  end

  defp legacy_llm(model) when is_binary(model), do: Map.get(@legacy_models, model, model)
  defp legacy_llm(model), do: model

  defp normalize_attr(key, values) when key in ["reads", "writes"] and is_list(values),
    do: Enum.map(values, &canonical_contract_field/1)

  defp normalize_attr("foreach", source) when is_binary(source), do: Map.get(@legacy_foreach_sources, source, source)

  defp normalize_attr("type", type) when is_map_key(@legacy_types, type), do: Map.fetch!(@legacy_types, type)

  defp normalize_attr("run", run) when is_binary(run),
    do: String.replace(run, Map.keys(@legacy_placeholders), &Map.fetch!(@legacy_placeholders, &1))

  defp normalize_attr(_key, value), do: value

  defp canonical_contract_field(field) do
    Enum.find_value(@legacy_contract_fields, field, fn {legacy, canonical} ->
      cond do
        field == legacy -> canonical
        field == Atom.to_string(legacy) -> Atom.to_string(canonical)
        true -> nil
      end
    end)
  end

  @doc "Validates one node; graph-level rules (key uniqueness) live on Schemas.Flow."
  def changeset(node, attrs) do
    node
    |> cast(normalize_legacy(attrs), @fields)
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
