defmodule Schemas.Flow do
  @moduledoc """
  A workflow definition (ADR 0006 / RLY-131): per-board declarative graph
  data. A flow belongs to exactly one main work/planning **stage** (RE429): `stage_id` is
  `NOT NULL` and unique (`flows_stage_id_index`), and deleting the stage deletes the flow.
  Where it picks cards up and drops them off is never stored — `pulls_from_stage` /
  `lands_on_stage` are virtual, filled from the board's current order by `Relay.Flows`'
  readers (`Relay.Flows.neighbours/2`); they are nil on a flow read any other way. So is the
  virtual `problem` (RE430): the flow's `Relay.Flows.Shape.problem/0` on a broken board shape,
  filled by `Relay.Flows.list_flows/1` / `get_flow_with_stages/2`, nil when healthy or read
  any other way. Nodes and edges
  are embedded jsonb; `"start"`/`"done"`/`"needs_input"` are edge-endpoint
  sentinels, not nodes — `"needs_input"` (RLY-194) is `to`-only and parks
  the run. `board_id` and `enabled` are set programmatically by
  `Relay.Flows`, never cast. `version` holds the current definition version;
  `flow_versions` snapshots each one.

  ## Fan-out regions (RE437)

  A `fan_out` node opens a **region**: each of its outgoing edges (which carry no `on`) starts a
  **branch**, and every branch ends at one shared `fan_in`. `regions/1` is the ONE place that
  pairing is worked out — `changeset/2`'s region rules, the engine and the UI all read it — and
  `region/2` / `enclosing_region/2` look a node up in it. Regions do not nest, and no `foreach`
  node or `when` guard may sit inside one; `changeset/2` names every broken shape.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # A fan_in joins on all-succeeded or any-failed, so those are the only outcomes it routes on.
  @fan_in_outcomes [:succeeded, :failed]

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
    # The flow's broken-board-shape problem (`Relay.Flows.Shape`, RE430), nil when healthy.
    field :problem, :any, virtual: true

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

  @typedoc "One branch of a region: the fan-out edge's `to` (`key`), its 0-based `position`, and its nodes."
  @type branch() :: %{key: String.t(), position: non_neg_integer(), nodes: [String.t()]}

  @typedoc "A `fan_out`'s region (RE437) — see `regions/1`."
  @type region() :: %{
          fan_out: String.t(),
          fan_in: String.t() | nil,
          max_parallel: pos_integer(),
          branches: [branch()]
        }

  @doc """
  Every `fan_out`'s region (RE437), one per `fan_out` node in node order. Takes a `%Schemas.Flow{}`
  or any map with `nodes` / `edges` lists (the Flow Editor's working copy), and never raises —
  the editor calls it on half-built flows.

    * `branches` follow the order of the `fan_out`'s outgoing edges: `key` is the edge's `to`,
      `position` is 0-based, and `nodes` lists every node reachable from `key` without passing
      the `fan_in`, in discovery order, `key` first.
    * `max_parallel` is the `fan_out`'s own, or else one per branch.
    * `fan_in` is the single `fan_in` every branch reaches, or nil when the shape is invalid.

  A walk that meets another `fan_out` passes through it and its `fan_in` (bracket matching), so
  a nested region — itself invalid — doesn't hide the outer `fan_in`.
  """
  @spec regions(%{nodes: [map()], edges: [map()]}) :: [region()]
  def regions(flow) do
    flow
    |> graph()
    |> analyze_regions()
    |> Enum.map(fn region ->
      region
      |> Map.take([:fan_out, :fan_in, :max_parallel])
      |> Map.put(:branches, Enum.map(region.branches, &Map.take(&1, [:key, :position, :nodes])))
    end)
  end

  @doc "Whether `key` names a `fan_out` node of `flow` (RE437)."
  @spec fan_out?(%{nodes: [map()]}, String.t()) :: boolean()
  def fan_out?(flow, key), do: Enum.any?(flow.nodes, &(&1.key == key and &1.type == :fan_out))

  @doc "The region opened by the `fan_out` keyed `key`, or nil (RE437)."
  @spec region(map(), String.t()) :: region() | nil
  def region(flow, key), do: Enum.find(regions(flow), &(&1.fan_out == key))

  @doc """
  The region `key` sits in — a branch node, or the region's `fan_in` — or nil (RE437). The
  `fan_out` that opens a region is not inside it, and neither is any node outside every region.
  """
  @spec enclosing_region(map(), String.t()) :: region() | nil
  def enclosing_region(flow, key) do
    Enum.find(regions(flow), fn region ->
      region.fan_in == key or Enum.any?(region.branches, &(key in &1.nodes))
    end)
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
    |> validate_regions()
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
    |> check(
      Enum.all?(rest, &(not is_nil(&1.on) or &1.from in fan_out_keys(changeset))),
      "every edge except the start edge requires an outcome"
    )
  end

  # Guarded edges may be plural on one {from, on} — that is the whole point of
  # `when` — so the uniqueness key includes the guard. Two UNGUARDED edges (or
  # two edges carrying the same guard) on one route are still ambiguous.
  # A fan_out's edges carry no outcome at all; two of them to one node is its own message.
  defp validate_unique_routing(changeset) do
    fan_outs = fan_out_keys(changeset)

    duplicated? =
      changeset
      |> edges()
      |> Enum.reject(&(&1.from in fan_outs))
      |> Enum.frequencies_by(&{&1.from, &1.on, &1.when})
      |> Enum.any?(fn {_route, count} -> count > 1 end)

    check(changeset, not duplicated?, "only one edge may leave a node per outcome")
  end

  # A guard reads the remaining count of THE flow's foreach node, so a guarded
  # edge without exactly one foreach node has nothing to read. Multi-foreach
  # flows are out of scope, and no foreach node may sit inside a fan-out region (RE437).
  defp validate_foreach_guards(changeset) do
    guarded? = Enum.any?(edges(changeset), &(not is_nil(&1.when)))
    heads = Enum.count(nodes(changeset), &(not is_nil(&1.foreach)))

    check(
      changeset,
      not guarded? or heads == 1,
      "a flow with guarded edges must have exactly one foreach node"
    )
  end

  # ---- fan-out regions (RE437) ----

  # Every region rule, each message naming the nodes/edges at fault. Each lands on `:edges`
  # except the region-shape rules (branches ending at different fan_ins, an edge leaving the
  # region) and the node-attribute rules (max_parallel, a control node doing work), on `:nodes`.
  defp validate_regions(changeset) do
    graph = graph(%{nodes: nodes(changeset), edges: edges(changeset)})
    regions = analyze_regions(graph)

    [
      fan_out_edge_errors(graph),
      branch_errors(regions),
      region_edge_errors(graph, regions),
      nesting_errors(graph, regions),
      fan_in_errors(graph, regions),
      node_attr_errors(graph),
      start_edge_errors(graph)
    ]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reduce(changeset, fn {field, message}, cs -> add_error(cs, field, message) end)
  end

  # Rules 1–3: a fan_out fires 2+ distinct edges, none of which carries an outcome or a guard.
  defp fan_out_edge_errors(graph) do
    for_result =
      for %{type: :fan_out, key: key} <- graph.nodes do
        out = Map.get(graph.out, key, [])

        [
          if(length(out) < 2, do: {:edges, ~s(fan_out "#{key}" needs at least two outgoing edges)}),
          for(
            edge <- out,
            field <- [:on, :when],
            Map.get(edge, field) != nil,
            do: {:edges, fan_out_edge_message(edge, field)}
          ),
          for(
            {to, count} <- Enum.frequencies_by(out, & &1.to),
            count > 1,
            do: {:edges, ~s(fan_out "#{key}" has two edges to "#{to}")}
          )
        ]
      end

    for_result
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp fan_out_edge_message(edge, field),
    do: ~s(edge "#{edge.from}" → "#{edge.to}" leaves a fan_out, which fires every edge on entry — remove "#{field}")

  # Rules 4–5: every branch reaches a fan_in, and all of them the same one.
  defp branch_errors(regions) do
    for_result =
      for region <- regions do
        [
          for(
            %{fan_ins: [], key: branch} <- region.branches,
            do: {:edges, ~s(branch "#{branch}" of fan_out "#{region.fan_out}" never reaches a fan_in)}
          ),
          if(length(region.reached) > 1,
            do: {:nodes, ~s{fan_out "#{region.fan_out}" branches end at different fan_ins (#{quoted(region.reached)})}}
          )
        ]
      end

    for_result
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # Rules 6, 7 and 15: an edge out of a region goes only to its fan_in (or parks on
  # needs_input), never crosses into a sibling branch, and carries no guard.
  defp region_edge_errors(graph, regions) do
    for_result =
      for region <- regions,
          homes = branch_homes(graph, region),
          edge <- graph.edges,
          MapSet.member?(region.inside, edge.from) do
        region_edge_error(region, homes, edge)
      end

    List.flatten(for_result)
  end

  defp region_edge_error(%{fan_out: fan_out} = region, homes, edge) do
    route = ~s(edge "#{edge.from}" → "#{edge.to}")

    Enum.reject(
      [
        if(Map.get(edge, :when) != nil,
          do: {:edges, ~s(#{route} inside the region of fan_out "#{fan_out}" carries a "when" guard)}
        ),
        cond do
          edge.to == needs_input_sentinel() or edge.to in region.reached ->
            nil

          not MapSet.member?(region.inside, edge.to) ->
            {:nodes, ~s(#{route} leaves the region of fan_out "#{fan_out}")}

          homes[edge.from] != homes[edge.to] ->
            {:edges,
             ~s(#{route} crosses between branches "#{homes[edge.from]}" and "#{homes[edge.to]}" of fan_out "#{fan_out}")}

          true ->
            nil
        end
      ],
      &is_nil/1
    )
  end

  # Rules 13–14: no fan_out and no foreach node inside a region.
  defp nesting_errors(graph, regions) do
    for_result =
      for region <- regions, node <- graph.nodes, MapSet.member?(region.inside, node.key) do
        cond do
          node.type == :fan_out ->
            {:edges,
             ~s(fan_out "#{node.key}" sits inside the region of fan_out "#{region.fan_out}" — fan-outs cannot nest)}

          Map.get(node, :foreach) != nil ->
            {:edges, ~s(foreach node "#{node.key}" sits inside the region of fan_out "#{region.fan_out}")}

          true ->
            nil
        end
      end

    Enum.reject(for_result, &is_nil/1)
  end

  # Rules 8–12: each fan_in closes exactly one fan_out, is entered only from its region, and
  # routes only on succeeded / failed (a guard only on succeeded).
  defp fan_in_errors(graph, regions) do
    node_keys = MapSet.new(graph.nodes, & &1.key)

    for_result =
      for %{type: :fan_in, key: key} <- graph.nodes do
        closers = Enum.filter(regions, &(key in &1.reached))
        out = Map.get(graph.out, key, [])

        [
          closing_error(key, closers),
          for(
            from <- graph.in |> Map.get(key, []) |> Enum.uniq(),
            closers != [] and MapSet.member?(node_keys, from),
            not Enum.any?(closers, &MapSet.member?(&1.inside, from)),
            do: {:edges, ~s(edge "#{from}" → "#{key}" enters fan_in "#{key}" from outside its region)}
          ),
          for(
            %{on: on} <- out,
            on not in [nil | @fan_in_outcomes],
            do: {:edges, ~s(fan_in "#{key}" may route only on succeeded or failed — remove its edge on #{on})}
          ),
          if(Enum.any?(out, &(Map.get(&1, :when) != nil and &1.on != :succeeded)),
            do: {:edges, ~s(fan_in "#{key}" may carry a "when" guard only on succeeded)}
          )
        ]
      end

    for_result
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp closing_error(key, []), do: {:edges, ~s(fan_in "#{key}" is not closed by any fan_out)}
  defp closing_error(_key, [_closer]), do: nil

  defp closing_error(key, closers),
    do: {:edges, ~s{fan_in "#{key}" closes more than one fan_out (#{closers |> Enum.map(& &1.fan_out) |> quoted()})}}

  # Rules 16–18: max_parallel only on a fan_out, and at least 1; a control node does no work.
  defp node_attr_errors(graph) do
    for_result =
      for node <- graph.nodes do
        max_parallel = Map.get(node, :max_parallel)

        [
          cond do
            is_nil(max_parallel) -> nil
            node.type != :fan_out -> {:nodes, ~s(node "#{node.key}": max_parallel is only valid on a fan_out)}
            max_parallel < 1 -> {:nodes, ~s(fan_out "#{node.key}": max_parallel must be at least 1)}
            true -> nil
          end,
          for(
            field <- Schemas.Flow.Node.work_fields(),
            node.type in Schemas.Flow.Node.control_types(),
            Map.get(node, field) != nil,
            do: {:nodes, ~s(#{node.type} "#{node.key}" does no work — remove "#{field}")}
          )
        ]
      end

    for_result
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # Rule 19: a run cannot begin by joining branches it never opened.
  defp start_edge_errors(graph) do
    for %{from: "start", to: to} <- graph.edges, Map.get(graph.types, to) == :fan_in do
      {:edges, ~s(the start edge cannot target fan_in "#{to}")}
    end
  end

  defp quoted(keys), do: keys |> Enum.sort() |> Enum.map_join(", ", &~s("#{&1}"))

  # The adjacency every region helper reads. `nodes` / `edges` are structs or plain maps.
  defp graph(%{nodes: nodes, edges: edges}) do
    nodes = nodes || []
    edges = edges || []

    %{
      nodes: nodes,
      edges: edges,
      types: Map.new(nodes, &{&1.key, &1.type}),
      out: Enum.group_by(edges, & &1.from),
      in: Enum.group_by(edges, & &1.to, & &1.from),
      max_depth: Enum.count(nodes, &(&1.type == :fan_out))
    }
  end

  # Each region with the working sets the validators need beside the public shape: per branch
  # the fan_ins it reaches; per region every fan_in reached (`reached`) and the node keys
  # inside it (`inside`).
  defp analyze_regions(graph) do
    for %{type: :fan_out} = node <- graph.nodes do
      branches =
        graph.out
        |> Map.get(node.key, [])
        |> Enum.with_index()
        |> Enum.map(fn {edge, position} ->
          Map.merge(%{key: edge.to, position: position}, walk_branch(graph, node.key, edge.to))
        end)

      reached = branches |> Enum.flat_map(& &1.fan_ins) |> Enum.uniq()

      %{
        fan_out: node.key,
        fan_in: paired_fan_in(branches, reached),
        max_parallel: Map.get(node, :max_parallel) || length(branches),
        branches: branches,
        reached: reached,
        inside: inside(graph, node.key, branches, reached)
      }
    end
  end

  defp paired_fan_in(branches, [fan_in]), do: if(Enum.all?(branches, &(&1.fan_ins != [])), do: fan_in)
  defp paired_fan_in(_branches, _reached), do: nil

  # A bounded breadth-first walk from a branch head, tracking fan-out nesting depth: an inner
  # fan_out goes one deeper and its fan_in comes back up, so only a fan_in met at depth 0 ends
  # the branch. `{node, depth}` pairs are visited once and depth is capped by the number of
  # fan_outs, so cycles terminate. Sentinels, unknown keys and the region's own fan_out stop it.
  defp walk_branch(graph, fan_out, head), do: walk(graph, fan_out, [{head, 0}], MapSet.new(), [], [])

  defp walk(_graph, _fan_out, [], _seen, nodes, fan_ins),
    do: %{nodes: nodes |> Enum.reverse() |> Enum.uniq(), fan_ins: fan_ins |> Enum.reverse() |> Enum.uniq()}

  defp walk(graph, fan_out, [{key, depth} = step | queue], seen, nodes, fan_ins) do
    type = Map.get(graph.types, key)

    cond do
      MapSet.member?(seen, step) or key == fan_out or is_nil(type) ->
        walk(graph, fan_out, queue, seen, nodes, fan_ins)

      type == :fan_in and depth == 0 ->
        walk(graph, fan_out, queue, MapSet.put(seen, step), nodes, [key | fan_ins])

      true ->
        depth = nested_depth(type, depth, graph.max_depth)
        next = for edge <- Map.get(graph.out, key, []), do: {edge.to, depth}
        walk(graph, fan_out, queue ++ next, MapSet.put(seen, step), [key | nodes], fan_ins)
    end
  end

  defp nested_depth(:fan_out, depth, max_depth), do: min(depth + 1, max_depth)
  defp nested_depth(:fan_in, depth, _max_depth), do: depth - 1
  defp nested_depth(_type, depth, _max_depth), do: depth

  # Inside the region: a branch head, or a branch node that can still reach the region's
  # fan_in(s) without passing back through the fan_out. A node a branch only wanders out to
  # (`c → after`) is reachable but outside, which is what makes that edge "leave the region".
  defp inside(graph, fan_out, branches, reached) do
    heads = MapSet.new(branches, & &1.key)
    joins = climb(graph, fan_out, reached, MapSet.new())

    for %{nodes: nodes} <- branches,
        key <- nodes,
        MapSet.member?(heads, key) or MapSet.member?(joins, key),
        into: MapSet.new(),
        do: key
  end

  # Every node that reaches one of `keys` backwards, never through `fan_out`.
  defp climb(_graph, _fan_out, [], seen), do: seen

  defp climb(graph, fan_out, [key | rest], seen) do
    if MapSet.member?(seen, key) or key == fan_out or not Map.has_key?(graph.types, key) do
      climb(graph, fan_out, rest, seen)
    else
      climb(graph, fan_out, Map.get(graph.in, key, []) ++ rest, MapSet.put(seen, key))
    end
  end

  # Each inside node's home branch: a breadth-first claim from every head at once, one level
  # at a time, edges taken in the flow's own order — so `a → b2` added beside `b1 → b2` leaves
  # `b2` in `b1`'s branch and the added edge is the one that crosses.
  defp branch_homes(graph, region) do
    heads = region.branches |> Enum.map(& &1.key) |> Enum.uniq() |> Enum.filter(&MapSet.member?(region.inside, &1))
    claim(graph.edges, region.inside, heads, Map.new(heads, &{&1, &1}))
  end

  defp claim(_edges, _inside, [], homes), do: homes

  defp claim(edges, inside, frontier, homes) do
    frontier = MapSet.new(frontier)

    {next, homes} =
      Enum.reduce(edges, {[], homes}, fn edge, {next, homes} ->
        if MapSet.member?(frontier, edge.from) and MapSet.member?(inside, edge.to) and not Map.has_key?(homes, edge.to) do
          {[edge.to | next], Map.put(homes, edge.to, Map.fetch!(homes, edge.from))}
        else
          {next, homes}
        end
      end)

    claim(edges, inside, Enum.reverse(next), homes)
  end

  defp fan_out_keys(changeset), do: for(%{type: :fan_out, key: key} <- nodes(changeset), do: key)

  defp check(changeset, true, _message), do: changeset
  defp check(changeset, false, message), do: add_error(changeset, :edges, message)

  defp node_keys(changeset), do: Enum.map(nodes(changeset), & &1.key)

  defp nodes(changeset), do: changeset |> get_field(:nodes) |> Kernel.||([])
  defp edges(changeset), do: changeset |> get_field(:edges) |> Kernel.||([])
end
