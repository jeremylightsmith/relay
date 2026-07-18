defmodule Schemas.Flow do
  @moduledoc """
  A workflow definition (ADR 0006 / RLY-131): per-board declarative graph
  data. The trigger is three stage FKs stored as **ids** (names are display-
  only via the preloaded associations) with `on_delete: :nilify_all` —
  deleting a stage disarms the flow rather than blocking. Nodes and edges
  are embedded jsonb; `"start"`/`"done"` are edge-endpoint sentinels, not
  nodes. `board_id` and `enabled` are set programmatically by `Relay.Flows`,
  never cast. `version` holds the current definition version;
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
    belongs_to :pulls_from_stage, Schemas.Stage
    belongs_to :works_in_stage, Schemas.Stage
    belongs_to :lands_on_stage, Schemas.Stage

    embeds_many :nodes, Schemas.Flow.Node, on_replace: :delete
    embeds_many :edges, Schemas.Flow.Edge, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a flow definition. `board_id` must already be set on the struct.
  Trigger-stage-belongs-to-board is validated in `Relay.Flows` — it needs
  the database, which the Schemas boundary (`deps: []`) can't reach.
  """
  def changeset(flow, attrs) do
    flow
    |> cast(attrs, [:key, :isolation, :pulls_from_stage_id, :works_in_stage_id, :lands_on_stage_id])
    |> validate_required([:key, :isolation])
    |> validate_format(:key, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/, message: "must be lowercase letters, numbers and dashes")
    |> cast_embed(:nodes)
    |> cast_embed(:edges)
    |> validate_unique_node_keys()
    |> validate_edge_endpoints()
    |> validate_start_edges()
    |> validate_unique_routing()
    |> validate_foreach_guards()
    |> unique_constraint(:key, name: :flows_board_id_key_index)
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
  # only appear as a `from`, "done" only as a `to` — a wrong-way sentinel
  # falls through to "does not name a node" (node keys can never be
  # sentinels, see Schemas.Flow.Node).
  defp validate_edge_endpoints(changeset) do
    keys = changeset |> node_keys() |> MapSet.new()

    changeset
    |> edges()
    |> Enum.reduce(changeset, fn edge, cs ->
      cond do
        edge.from != "start" and not MapSet.member?(keys, edge.from) ->
          add_error(cs, :edges, ~s(edge from "#{edge.from}" does not name a node))

        edge.to != "done" and not MapSet.member?(keys, edge.to) ->
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
