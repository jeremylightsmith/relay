defmodule Dagre.Graph do
  @moduledoc """
  A minimal functional directed multigraph over plain maps.

  Edges are keyed by a caller-supplied id, so two nodes may be joined by several
  edges. Every listing (`nodes/1`, `edges/1`, `in_edges/2`, …) comes back in
  insertion order, which is what makes the layout pipeline deterministic.

  An edge is reported as a `{id, from, to}` tuple; its attributes are read with
  `edge/2`.
  """

  defstruct nodes: %{}, node_ids: [], edges: %{}, edge_ids: [], out: %{}, in: %{}

  @type id :: term()
  @type edge :: {id(), id(), id()}
  @type t :: %__MODULE__{
          nodes: %{id() => map()},
          node_ids: [id()],
          edges: %{id() => %{from: id(), to: id(), attrs: map()}},
          edge_ids: [id()],
          out: %{id() => [id()]},
          in: %{id() => [id()]}
        }

  @doc "An empty graph."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds node `id` with `attrs`; re-adding an existing node merges the attrs."
  @spec add_node(t(), id(), map()) :: t()
  def add_node(%__MODULE__{} = graph, id, attrs \\ %{}) do
    if Map.has_key?(graph.nodes, id) do
      %{graph | nodes: Map.update!(graph.nodes, id, &Map.merge(&1, attrs))}
    else
      %{
        graph
        | nodes: Map.put(graph.nodes, id, attrs),
          node_ids: [id | graph.node_ids],
          out: Map.put(graph.out, id, []),
          in: Map.put(graph.in, id, [])
      }
    end
  end

  @doc "Adds edge `id` from `from` to `to`. Both nodes must exist; the id must be new."
  @spec add_edge(t(), id(), id(), id(), map()) :: t()
  def add_edge(%__MODULE__{} = graph, id, from, to, attrs \\ %{}) do
    if Map.has_key?(graph.edges, id), do: raise(ArgumentError, "edge #{inspect(id)} already exists")
    ensure_node!(graph, from)
    ensure_node!(graph, to)

    %{
      graph
      | edges: Map.put(graph.edges, id, %{from: from, to: to, attrs: attrs}),
        edge_ids: [id | graph.edge_ids],
        out: Map.update!(graph.out, from, &[id | &1]),
        in: Map.update!(graph.in, to, &[id | &1])
    }
  end

  @doc "Removes edge `id`. Removing an absent edge is a no-op."
  @spec remove_edge(t(), id()) :: t()
  def remove_edge(%__MODULE__{} = graph, id) do
    case Map.fetch(graph.edges, id) do
      {:ok, %{from: from, to: to}} ->
        %{
          graph
          | edges: Map.delete(graph.edges, id),
            edge_ids: List.delete(graph.edge_ids, id),
            out: Map.update!(graph.out, from, &List.delete(&1, id)),
            in: Map.update!(graph.in, to, &List.delete(&1, id))
        }

      :error ->
        graph
    end
  end

  @doc "Node ids in insertion order."
  @spec nodes(t()) :: [id()]
  def nodes(%__MODULE__{node_ids: ids}), do: Enum.reverse(ids)

  @doc "Whether node `id` exists."
  @spec has_node?(t(), id()) :: boolean()
  def has_node?(%__MODULE__{nodes: nodes}, id), do: Map.has_key?(nodes, id)

  @doc "The attrs of node `id`."
  @spec node(t(), id()) :: map()
  def node(%__MODULE__{nodes: nodes}, id), do: Map.fetch!(nodes, id)

  @doc "Sets one attr on node `id`."
  @spec put_node_attr(t(), id(), term(), term()) :: t()
  def put_node_attr(%__MODULE__{} = graph, id, key, value) do
    %{graph | nodes: Map.update!(graph.nodes, id, &Map.put(&1, key, value))}
  end

  @doc "Every edge as `{id, from, to}`, in insertion order."
  @spec edges(t()) :: [edge()]
  def edges(%__MODULE__{} = graph), do: graph.edge_ids |> Enum.reverse() |> Enum.map(&edge_tuple(graph, &1))

  @doc "The attrs of edge `id`."
  @spec edge(t(), id()) :: map()
  def edge(%__MODULE__{edges: edges}, id), do: Map.fetch!(edges, id).attrs

  @doc "The `{from, to}` endpoints of edge `id`."
  @spec endpoints(t(), id()) :: {id(), id()}
  def endpoints(%__MODULE__{edges: edges}, id) do
    %{from: from, to: to} = Map.fetch!(edges, id)
    {from, to}
  end

  @doc "Sets one attr on edge `id`."
  @spec put_edge_attr(t(), id(), term(), term()) :: t()
  def put_edge_attr(%__MODULE__{} = graph, id, key, value) do
    %{graph | edges: Map.update!(graph.edges, id, &%{&1 | attrs: Map.put(&1.attrs, key, value)})}
  end

  @doc "Edges entering `v`, in insertion order."
  @spec in_edges(t(), id()) :: [edge()]
  def in_edges(%__MODULE__{} = graph, v),
    do: graph.in |> Map.fetch!(v) |> Enum.reverse() |> Enum.map(&edge_tuple(graph, &1))

  @doc "Edges leaving `v`, in insertion order."
  @spec out_edges(t(), id()) :: [edge()]
  def out_edges(%__MODULE__{} = graph, v),
    do: graph.out |> Map.fetch!(v) |> Enum.reverse() |> Enum.map(&edge_tuple(graph, &1))

  @doc "Distinct sources of the edges entering `v`, in insertion order."
  @spec predecessors(t(), id()) :: [id()]
  def predecessors(graph, v), do: graph |> in_edges(v) |> Enum.map(fn {_, from, _} -> from end) |> Enum.uniq()

  @doc "Distinct targets of the edges leaving `v`, in insertion order."
  @spec successors(t(), id()) :: [id()]
  def successors(graph, v), do: graph |> out_edges(v) |> Enum.map(fn {_, _, to} -> to end) |> Enum.uniq()

  defp edge_tuple(graph, id) do
    %{from: from, to: to} = Map.fetch!(graph.edges, id)
    {id, from, to}
  end

  defp ensure_node!(graph, id) do
    unless Map.has_key?(graph.nodes, id), do: raise(ArgumentError, "unknown node #{inspect(id)}")
  end
end
