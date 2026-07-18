defmodule RelayWeb.FlowLayout do
  @moduledoc """
  Deterministic, pure serpentine layout for a flow graph — no stored coordinates, no dragging.
  Derives the artboard's shape from graph structure alone: follow the `:succeeded` spine, snake
  it into rows of <= 6, hang fix nodes in a row below under their reviewer's column, and park
  anything unreachable below that. Reused read-only by the run panel (RLY-132+).
  Reference: docs/designs/Relay Flow Editor.dc.html.
  """

  # No `use Boundary` — this is a pure web-layer helper inside the RelayWeb boundary, like
  # CoreComponents/FlowSettingsComponents. Declaring a nested sub-boundary here would fail
  # compilation.

  @cols 6
  @col_w 185
  @row_h 142
  @node_w 150
  @node_h 76
  @origin_x 8
  @origin_y 34

  @spec layout([map], [map]) :: %{
          positions: %{optional(String.t()) => {integer, integer}},
          size: {integer, integer},
          routes: %{optional(integer) => atom}
        }
  def layout(nodes, edges) do
    node_keys = MapSet.new(nodes, &key(&1))
    spine = spine_order(edges, node_keys)
    spine_grid = serpentine(spine)

    fix_grid = place_fix(nodes, edges, MapSet.new(spine), spine_grid)
    placed = Map.merge(spine_grid, fix_grid)

    park_grid = park(nodes, placed)
    grid = Map.merge(placed, park_grid)

    positions =
      Map.new(grid, fn {k, {r, c}} -> {k, {@origin_x + c * @col_w, @origin_y + r * @row_h}} end)

    routes =
      edges
      |> Enum.with_index()
      |> Map.new(fn {e, i} -> {i, route_kind(e, grid)} end)

    %{positions: positions, size: size(positions), routes: routes}
  end

  # Follow the single start edge's target, then first-unvisited :succeeded edges to "done".
  defp spine_order(edges, node_keys) do
    start = Enum.find(edges, &(&1.from == "start"))
    walk(start && start.to, edges, node_keys, MapSet.new(), [])
  end

  defp walk(nil, _edges, _keys, _seen, acc), do: Enum.reverse(acc)
  defp walk("done", _edges, _keys, _seen, acc), do: Enum.reverse(acc)

  defp walk(key, edges, node_keys, seen, acc) do
    cond do
      MapSet.member?(seen, key) ->
        Enum.reverse(acc)

      not MapSet.member?(node_keys, key) ->
        Enum.reverse(acc)

      true ->
        seen = MapSet.put(seen, key)
        next = next_spine_target(edges, key, seen)
        walk(next, edges, node_keys, seen, [key | acc])
    end
  end

  # A `foreach` loop head (W13) may leave TWO :succeeded edges — one guarded
  # `foreach_remaining` back to itself, one guarded `foreach_exhausted` onward
  # — so the first-listed edge is no longer necessarily the spine's next
  # step. Prefer whichever candidate does NOT loop back to an already-visited
  # node (`seen` already includes `key`, so a self-loop is excluded too);
  # the spine should keep moving forward.
  defp next_spine_target(edges, key, seen) do
    candidates = for %{from: ^key, to: to} = e <- edges, Map.get(e, :on) == :succeeded, do: to
    Enum.find(candidates, &(not MapSet.member?(seen, &1))) || List.first(candidates)
  end

  defp serpentine(spine) do
    spine
    |> Enum.chunk_every(@cols)
    |> Enum.with_index()
    |> Enum.flat_map(&serpentine_row/1)
    |> Map.new()
  end

  defp serpentine_row({row, r}) do
    for {k, c} <- Enum.with_index(row) do
      col = if rem(r, 2) == 1, do: @cols - 1 - c, else: c
      {k, {r, col}}
    end
  end

  defp place_fix(nodes, edges, spine_set, spine_grid) do
    fix_row = 1 + max_row(spine_grid)

    nodes
    |> Enum.map(&key/1)
    |> Enum.reject(&MapSet.member?(spine_set, &1))
    |> Enum.reduce({%{}, MapSet.new()}, fn k, {acc, taken} ->
      case partner_col(k, edges, spine_grid) do
        nil ->
          {acc, taken}

        col ->
          col = first_free(col, taken)
          {Map.put(acc, k, {fix_row, col}), MapSet.put(taken, col)}
      end
    end)
    |> elem(0)
  end

  defp partner_col(key, edges, spine_grid) do
    partner = Enum.find_value(edges, &partner_of(&1, key, spine_grid))

    case partner && Map.get(spine_grid, partner) do
      {_r, c} -> c
      _ -> nil
    end
  end

  # An edge names `key`'s partner when it links `key` to an already-placed spine node: a
  # `:failed` edge landing on `key` (the reviewer) or a `:succeeded` edge leaving `key`.
  defp partner_of(%{to: key, from: from} = e, key, spine_grid) do
    if Map.get(e, :on) == :failed and Map.has_key?(spine_grid, from), do: from
  end

  defp partner_of(%{from: key, to: to} = e, key, spine_grid) do
    if Map.get(e, :on) == :succeeded and Map.has_key?(spine_grid, to), do: to
  end

  defp partner_of(_edge, _key, _spine_grid), do: nil

  defp first_free(col, taken) do
    if MapSet.member?(taken, col), do: first_free(col + 1, taken), else: col
  end

  defp park(nodes, placed) do
    park_row = 1 + max_row(placed)

    nodes
    |> Enum.map(&key/1)
    |> Enum.reject(&Map.has_key?(placed, &1))
    |> Enum.with_index()
    |> Map.new(fn {k, i} -> {k, {park_row, i}} end)
  end

  defp route_kind(%{from: "start"}, _grid), do: :enter
  defp route_kind(%{to: "done"}, _grid), do: :exit

  defp route_kind(edge, grid) do
    with {fr, fc} <- Map.get(grid, edge.from),
         {tr, tc} <- Map.get(grid, edge.to) do
      cond do
        tr > fr -> :drop
        tr < fr -> :arc
        tc < fc -> :arc
        fc == tc -> :vertical
        true -> :horizontal
      end
    else
      _ -> :straight
    end
  end

  defp size(positions) when map_size(positions) == 0, do: {@col_w, @row_h}

  defp size(positions) do
    xs = Enum.map(positions, fn {_k, {x, _y}} -> x end)
    ys = Enum.map(positions, fn {_k, {_x, y}} -> y end)
    {Enum.max(xs) + @node_w + @origin_x, Enum.max(ys) + @node_h + @origin_y}
  end

  defp max_row(grid) when map_size(grid) == 0, do: -1
  defp max_row(grid), do: grid |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.max()

  defp key(%{key: k}), do: k
end
