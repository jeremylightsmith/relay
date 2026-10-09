defmodule Schemas.Flow do
  @moduledoc """
  A workflow definition (ADR 0006 / RLY-131): per-board declarative graph
  data. A flow belongs to exactly one main work/planning **stage** (RE429): `stage_id` is
  `NOT NULL` and unique (`flows_stage_id_index`), and deleting the stage deletes the flow.
  Where it picks cards up and drops them off is never stored — `pulls_from_stage` /
  `lands_on_stage` are virtual, filled from the board's current order by `Relay.Flows`'
  readers (`Relay.Flows.neighbours/2`); they are nil on a flow read any other way. Nodes and edges
  are embedded jsonb; `"start"`/`"done"`/`"needs_input"` are edge-endpoint
  sentinels, not nodes — `"needs_input"` (RLY-194) is `to`-only and parks
  the run. `board_id` and `enabled` are set programmatically by
  `Relay.Flows`, never cast. `version` holds the current definition version;
  `flow_versions` snapshots each one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "flows" do
    field :key, :string
    field :version, :integer, default: 1
    field :enabled, :boolean, default: false
    field :isolation, Ecto.Enum, values: [:shared_clean, :exclusive]

    belongs_to :board, Schemas.Board
    belongs_to :stage, Schemas.Stage

    # Worked out from board order on read (RE429), never persisted.
    field :pulls_from_stage, :any, virtual: true
    field :lands_on_stage, :any, virtual: true

    embeds_many :nodes, Schemas.Flow.Node, on_replace: :delete
    embeds_many :edges, Schemas.Flow.Edge, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The closed set of flow isolation classes."
  def isolation_classes, do: Ecto.Enum.values(__MODULE__, :isolation)

  @doc ~S|The `to`-only edge sentinel that parks the run on a human (RLY-194): `"needs_input"`.|
  def needs_input_sentinel, do: "needs_input"

  @doc """
  The node a run of this flow begins at: the `to` of its single `"start"` edge.

  The `"start"` sentinel is spelled in this module (see `validate_start_edges/1`, which makes
  "exactly one edge leaves start" an invariant), so every consumer asks this function rather
  than re-finding that edge — `Relay.Runs.start_run/3` for a fresh run, and retry's re-adoption
  of a replaced flow (`Relay.Runs.retry_run/2`, RE297).

  Returns `"done"` for a flow whose start edge goes straight to the done sentinel (an empty
  flow), and `nil` for a struct with no start edge at all — a shape the changeset rejects, so
  callers may treat both as "there is no first node".
  """
  def start_node(%__MODULE__{edges: edges}) do
    case Enum.find(edges || [], &(&1.from == "start")) do
      nil -> nil
      edge -> edge.to
    end
  end

  @doc """
  Every node's role (RE346), as `%{node_key => :do | :check | :fix}` — the ONE place the rule
  lives; the value stream map (RE349) and any future display call this rather than re-deriving
  it. Pure and display-only: the engine and the runner never branch on a role.

  First match wins:

    1. the node's authored `role` — it always wins, whatever the graph says;
    2. `:fix` — the node has at least one inbound edge and every inbound edge is `on: :failed`.
       The `"start"` edge counts as inbound and is never `:failed`, so an unannotated start node
       is never guessed `:fix`;
    3. `:check` — a `:gate` node;
    4. `:do`.
  """
  def node_roles(%__MODULE__{nodes: nodes, edges: edges}) do
    inbound = Enum.group_by(edges || [], & &1.to, & &1.on)
    Map.new(nodes || [], &{&1.key, node_role(&1, Map.get(inbound, &1.key, []))})
  end

  defp node_role(%Schemas.Flow.Node{role: role}, _inbound) when not is_nil(role), do: role

  defp node_role(%Schemas.Flow.Node{type: type}, inbound) do
    cond do
      inbound != [] and Enum.all?(inbound, &(&1 == :failed)) -> :fix
      type == :gate -> :check
      true -> :do
    end
  end

  @doc """
  Validates a flow definition. `board_id` must already be set on the struct.
  Whether the stage is on the board, a main work stage and free is validated in `Relay.Flows` —
  it needs the database, which the Schemas boundary (`deps: []`) can't reach; the unique index
  is the race backstop.
  """
  def changeset(flow, attrs) do
    flow
    |> cast(attrs, [:key, :isolation, :stage_id])
    |> validate_required([:key, :isolation, :stage_id])
    |> validate_format(:key, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, message: "must be lowercase letters, numbers and dashes")
    |> cast_embed(:nodes)
    |> cast_embed(:edges)
    |> validate_unique_node_keys()
    |> validate_edge_endpoints()
    |> validate_start_edges()
    |> validate_unique_routing()
    |> validate_foreach_guards()
    |> unique_constraint(:key, name: :flows_board_id_key_index)
    |> unique_constraint(:stage_id, name: :flows_stage_id_index, message: "stage already has a flow")
  end

  defp validate_unique_node_keys(changeset) do
    keys = changeset |> node_keys() |> Enum.reject(&is_nil/1)

    if Enum.uniq(keys) == keys do
      changeset
    else
      add_error(changeset, :nodes, "node keys must be unique within the flow")
    end
  end

  # Every endpoint must be a node key or the correct sentinel: "start" may
  # only appear as a `from`, "done"/"needs_input" only as a `to` — a wrong-way
  # sentinel falls through to "does not name a node" (node keys can never be
  # sentinels, see Schemas.Flow.Node).
  defp validate_edge_endpoints(changeset) do
    keys = changeset |> node_keys() |> MapSet.new()

    changeset
    |> edges()
    |> Enum.reduce(changeset, fn edge, cs ->
      cond do
        edge.from != "start" and not MapSet.member?(keys, edge.from) ->
          add_error(cs, :edges, ~s(edge from "#{edge.from}" does not name a node))

        edge.to not in ["done", "needs_input"] and not MapSet.member?(keys, edge.to) ->
          add_error(cs, :edges, ~s(edge to "#{edge.to}" does not name a node))

        true ->
          cs
      end
    end)
  end

  defp validate_start_edges(changeset) do
    {start_edges, rest} = Enum.split_with(edges(changeset), &(&1.from == "start"))

    changeset
    |> check(length(start_edges) == 1, "exactly one edge must leave start")
    |> check(Enum.all?(start_edges, &is_nil(&1.on)), "the start edge cannot carry an outcome")
    |> check(Enum.all?(rest, &(not is_nil(&1.on))), "every edge except the start edge requires an outcome")
  end

  # Guarded edges may be plural on one {from, on} — that is the whole point of
  # `when` — so the uniqueness key includes the guard. Two UNGUARDED edges (or
  # two edges carrying the same guard) on one route are still ambiguous.
  defp validate_unique_routing(changeset) do
    duplicated? =
      changeset
      |> edges()
      |> Enum.frequencies_by(&{&1.from, &1.on, &1.when})
      |> Enum.any?(fn {_route, count} -> count > 1 end)

    check(changeset, not duplicated?, "only one edge may leave a node per outcome")
  end

  # A guard reads the remaining count of THE flow's foreach node, so a guarded
  # edge without exactly one foreach node has nothing to read. Multi-foreach
  # flows are out of scope (fan-out belongs to `parallel`, RLY-161).
  defp validate_foreach_guards(changeset) do
    guarded? = Enum.any?(edges(changeset), &(not is_nil(&1.when)))
    heads = Enum.count(nodes(changeset), &(not is_nil(&1.foreach)))

    check(
      changeset,
      not guarded? or heads == 1,
      "a flow with guarded edges must have exactly one foreach node"
    )
  end

  defp check(changeset, true, _message), do: changeset
  defp check(changeset, false, message), do: add_error(changeset, :edges, message)

  defp node_keys(changeset), do: Enum.map(nodes(changeset), & &1.key)

  defp nodes(changeset), do: changeset |> get_field(:nodes) |> Kernel.||([])
  defp edges(changeset), do: changeset |> get_field(:edges) |> Kernel.||([])
end
