defmodule Hamaca.Runs.Track do
  @moduledoc """
  Where a run sits on its flow, as the card face's progress bar sees it (RE513). Pure: no
  `Repo` access. It is the ONE home of zone logic: the web layer renders what this module
  returns and never re-derives a zone or a step label.

  `zones/1` classifies a flow's nodes from the flow's shape alone (no flow field): the happy
  path (`Hamaca.Runs.happy_path/1`) splits at the `foreach` loop head
  (`Hamaca.Runs.foreach_node_key/1`) into **setup** (before it), **loop** (from it through the
  source of the `when: :foreach_remaining` loop-back edge) and **after** (the rest). An
  off-path node (a fix node) takes the latest zone among the happy-path nodes that feed it. A
  flow with no `foreach` on its happy path has no zones (nil).

  `build/4` turns zones plus a run's current node and executed keys into the run summary's
  `track` entry. Reached counts only move forward: they come from the furthest node the run
  has executed in a zone, so a fix node never drains the bar.

  `face/2` turns a run summary plus the card's task progress into the face's render-ready
  model: an ordered cell list (one setup notch, one notch per task, one after track) and a
  label. The component only maps it to markup.
  """

  alias Hamaca.Runs

  @type zone :: :setup | :loop | :after
  @type zones :: %{
          setup: [String.t()],
          loop: [String.t()],
          after: [String.t()],
          foreach: String.t(),
          off_path: %{String.t() => zone()}
        }
  @type track :: %{
          zone: zone(),
          step: String.t(),
          previous_node: String.t() | nil,
          setup_total: non_neg_integer(),
          setup_reached: non_neg_integer(),
          after_total: non_neg_integer(),
          after_reached: non_neg_integer()
        }
  @type cell_state :: :done | :current | :pending
  @type cell ::
          {:setup, cell_state()}
          | {:task, cell_state()}
          | {:after, %{fill_pct: float(), tail_pct: float(), striped?: boolean()}}

  # Zone order, earliest first: an off-path node fed from several zones takes the latest.
  @zone_order [:setup, :loop, :after]

  @doc "A flow's setup / loop / after zones, or nil when its happy path has no `foreach` node."
  @spec zones(Schemas.Flow.t()) :: zones() | nil
  def zones(%Schemas.Flow{} = flow) do
    path = Runs.happy_path(flow)
    foreach = Runs.foreach_node_key(flow)

    if foreach && foreach in path do
      {setup, from_loop} = Enum.split_while(path, &(&1 != foreach))
      {loop, after_loop} = Enum.split(from_loop, loop_length(flow, foreach, from_loop))
      on_path = %{setup: setup, loop: loop, after: after_loop}

      Map.merge(on_path, %{foreach: foreach, off_path: off_path(flow, path, on_path)})
    end
  end

  # The loop runs from the foreach head through the source of its `foreach_remaining` loop-back
  # edge. Found by searching edges, not walking: happy_path/1 keeps the last `:succeeded` edge.
  defp loop_length(%{edges: edges}, foreach, from_loop) do
    with %{from: loop_end} <- Enum.find(edges, &(&1.to == foreach and &1.when == :foreach_remaining)),
         index when is_integer(index) <- Enum.find_index(from_loop, &(&1 == loop_end)) do
      index + 1
    else
      _ -> 1
    end
  end

  defp off_path(%{nodes: nodes, edges: edges}, path, on_path) do
    node_keys = MapSet.new(nodes, & &1.key)
    zone_by_key = Map.new(for {zone, keys} <- on_path, key <- keys, do: {key, zone})

    edges
    |> Enum.filter(&(Map.has_key?(zone_by_key, &1.from) and &1.to in node_keys and &1.to not in path))
    |> Enum.group_by(& &1.to, &zone_by_key[&1.from])
    |> Map.new(fn {key, zones} -> {key, Enum.max_by(zones, &zone_rank/1)} end)
  end

  defp zone_rank(zone), do: Enum.find_index(@zone_order, &(&1 == zone))

  @doc "The zone `node_key` belongs to, or nil when it is in none (or is nil)."
  @spec zone_of(zones(), String.t() | nil) :: zone() | nil
  def zone_of(_zones, nil), do: nil

  def zone_of(zones, node_key) do
    Enum.find(@zone_order, &(node_key in Map.fetch!(zones, &1))) || Map.get(zones.off_path, node_key)
  end

  @doc ~S|A node key as a step label: `"final_review"` → `"final review"`, `""` for nil.|
  @spec step_name(String.t() | nil) :: String.t()
  def step_name(nil), do: ""
  def step_name(node_key), do: String.replace(node_key, "_", " ")

  @doc """
  The run summary's `track` entry: the current node's zone and step label, the node before it,
  and how far the run has reached in the setup and after zones. `recent` is the run's two most
  recent executed keys, newest first. Nil without zones, a current node, or a zone for it.
  """
  @spec build(zones() | nil, String.t() | nil, [String.t()], [String.t()]) :: track() | nil
  def build(nil, _current, _executed, _recent), do: nil
  def build(_zones, nil, _executed, _recent), do: nil

  def build(zones, current, executed, recent) do
    case zone_of(zones, current) do
      nil ->
        nil

      zone ->
        previous = previous_node(current, recent)
        seen = executed ++ [current]

        %{
          zone: zone,
          step: step(zone, zones, current, previous),
          previous_node: previous,
          setup_total: length(zones.setup),
          setup_reached: reached(zones.setup, seen),
          after_total: length(zones.after),
          after_reached: reached(zones.after, seen)
        }
    end
  end

  # The current node may not have an execution yet, so recent[0] is either it or the node before.
  defp previous_node(current, [current | rest]), do: List.first(rest)
  defp previous_node(_current, recent), do: List.first(recent)

  # The 1-based position of the furthest `seen` node in `keys`, or 0 when none is in it.
  defp reached(keys, seen) do
    keys
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {key, position}, acc -> if key in seen, do: position, else: acc end)
  end

  defp step(:setup, _zones, current, _previous), do: step_name(current)

  defp step(:loop, %{foreach: current}, current, _previous), do: "building"

  defp step(:loop, zones, current, previous) do
    cond do
      loop_fix?(zones, current) -> "fixing review notes"
      loop_fix?(zones, previous) -> "re-reviewing"
      true -> "reviewing"
    end
  end

  defp step(:after, zones, current, previous) do
    cond do
      not Map.has_key?(zones.off_path, current) -> step_name(current)
      previous -> "fixing " <> step_name(previous)
      true -> "fixing"
    end
  end

  defp loop_fix?(zones, node_key), do: Map.get(zones.off_path, node_key) == :loop

  @doc """
  The run face's bar: `cells` in order (one `:setup`, one `:task` per task, one `:after`) and
  its `label`. With no `track`, or no tasks, there is no bar: `cells` is `[]` and the label is
  the flow and the current step. Exactly one cell is current (or the after track striped).
  """
  @spec face(map(), %{done: non_neg_integer(), total: non_neg_integer()} | nil) :: %{
          cells: [cell()],
          label: String.t()
        }
  def face(summary, tasks) do
    case Map.get(summary, :track) do
      %{zone: _} = track when is_map(tasks) and tasks.total > 0 -> bar(track, tasks)
      _ -> %{cells: [], label: "#{summary.flow_key} · #{step_name(summary.current_node)}"}
    end
  end

  defp bar(%{zone: zone, step: step} = track, %{done: done, total: total}) do
    n = min(done + 1, total)
    {setup, task_state, striped?} = cell_rule(zone, n)

    after_cell = %{
      fill_pct: pct(track.after_reached, track.after_total),
      tail_pct: pct(1, track.after_total),
      striped?: striped?
    }

    tasks = for index <- 1..total, do: {:task, task_state.(index)}

    %{cells: [{:setup, setup}] ++ tasks ++ [{:after, after_cell}], label: label(zone, step, n, total, track)}
  end

  # {setup state, task index → state, after striped?} for the zone the run is in.
  defp cell_rule(:setup, _n), do: {:current, fn _index -> :pending end, false}
  defp cell_rule(:loop, n), do: {:done, &loop_task_state(&1, n), false}
  defp cell_rule(:after, _n), do: {:done, fn _index -> :done end, true}

  defp loop_task_state(index, n) when index < n, do: :done
  defp loop_task_state(n, n), do: :current
  defp loop_task_state(_index, _n), do: :pending

  defp label(:setup, step, _n, total, _track), do: "setup · #{step} · #{total} tasks to go"
  defp label(:loop, step, n, total, %{after_reached: 0}), do: "task #{n} of #{total} · #{step}"
  defp label(:loop, step, n, total, _track), do: "task #{n} of #{total} · new · #{step}"
  defp label(:after, step, _n, _total, _track), do: "tasks done · #{step}"

  # A share of the after track as a one-decimal percentage. `/` always yields a float.
  defp pct(_count, 0), do: 0.0
  defp pct(count, total), do: Float.round(count * 100 / total, 1)
end
