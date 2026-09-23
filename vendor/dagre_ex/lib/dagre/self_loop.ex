defmodule Dagre.SelfLoop do
  @moduledoc """
  Self-loops (edges with `from == to`).

  They are taken out before cycle breaking — a self-loop has no rank to span —
  and routed afterwards as a small stub loop off the right side of their node.
  `plan/2` reserves the room up front: each loop gets a *slot* to the right of
  the node (`edgesep` for the loop, plus `edgesep + label width` when it carries
  a label), and the node's layout width grows by the slots' total, so ordering
  and positioning keep every neighbour clear of the loop and its label.
  """

  @type loop :: %{id: term(), from: term(), label: {non_neg_integer(), non_neg_integer()} | nil}
  @type slot :: %{id: term(), offset: non_neg_integer(), label: {non_neg_integer(), non_neg_integer()} | nil}
  @type plan :: %{term() => %{slots: [slot()], width: non_neg_integer(), height: non_neg_integer()}}

  @doc """
  Groups `loops` by node. For each node: its slots in input order, the extra
  width to reserve, and the minimum layout height (the tallest loop label).
  """
  @spec plan([loop()], non_neg_integer()) :: plan()
  def plan(loops, edgesep) do
    loops
    |> Enum.group_by(& &1.from)
    |> Map.new(fn {node, loops} ->
      {slots, width} =
        Enum.map_reduce(loops, 0, fn loop, offset ->
          {%{id: loop.id, offset: offset, label: loop.label}, offset + slot_width(loop.label, edgesep)}
        end)

      height = loops |> Enum.map(fn loop -> label_height(loop.label) end) |> Enum.max()
      {node, %{slots: slots, width: width, height: height}}
    end)
  end

  @doc """
  Routes one slot's loop for a node whose caller-visible box is `box` and whose
  layout box (box plus reserved slots) is `layout_box`.

  The loop leaves the box's right side a quarter of its height above centre,
  runs out to the slot's vertical, and returns a quarter below centre. Its label
  sits in the slot, right of that vertical, centred on the layout box.
  """
  @spec route(
          {integer(), integer(), integer(), integer()},
          {integer(), integer(), integer(), integer()},
          slot(),
          non_neg_integer()
        ) :: %{points: [{integer(), integer()}], label: {integer(), integer()} | nil}
  def route({x, y, w, h}, {_lx, ly, _lw, lh}, slot, edgesep) do
    outer = x + w + slot.offset + edgesep
    centre = y + div(h, 2)
    rise = div(h, 4)

    points = [{x + w, centre - rise}, {outer, centre - rise}, {outer, centre + rise}, {x + w, centre + rise}]

    label =
      case slot.label do
        nil -> nil
        {label_w, _} -> {outer + edgesep + div(label_w, 2), ly + div(lh, 2)}
      end

    %{points: points, label: label}
  end

  defp slot_width(nil, edgesep), do: edgesep
  defp slot_width({label_w, _}, edgesep), do: 2 * edgesep + label_w

  defp label_height(nil), do: 0
  defp label_height({_, label_h}), do: label_h
end
