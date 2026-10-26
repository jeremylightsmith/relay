defmodule Hamaca.Runs.RunDetail do
  @moduledoc """
  The run-visibility read model (RLY-207). Everything the drawer Run tab and
  the run-history entries need, derived ONCE in the domain from a run with its
  `node_executions` preloaded plus the run's flow — so the web layer renders it
  instead of re-folding raw executions. Pure: no `Repo` access.

  The forensics helpers here (`row_state/2`, `resumed?/2`, `synthetic_active/2`,
  `pending_tail/3`, `tripped_node/2`, `last_failure_detail/1`, `parked_attempt/2`,
  `type_tag/2`, `failure_reason/1`, timeline assembly) moved out of
  `HamacaWeb.RunComponents` unchanged in behavior. Copy rule (ADR 0006):
  "session resumed" ONLY after a needs-input re-entry — or a Steer now restart (RE358) whose
  stopped attempt had a known session — never a review-failed loop. A `:steered` attempt reads
  `state: :steered, steered?: true` and, like a `:blocked` wait, is not a spent attempt.

  `run` fields are read by dot/`Map.get` access so both a `%Schemas.Run{}` and a
  plain test/story map work; `:node_executions` may be `nil` (treated as `[]`), and so may
  `:run_branches` (RE437 — nil, absent or not loaded is treated as `[]`).

  Fan-out regions (RE437) are grouped (RE440): when `run_branches` is a list, each `fan_out`
  execution that opened a region entry becomes one `:region` timeline row — the `fan_out`'s node
  row as `header`, a `branch_tally/1` `tally`, and one lane per branch in `position` order (never
  start order), each holding that branch's executions with loop rows computed within the lane. A
  `:queued` branch with no execution gets a `state: :queued` placeholder row. A joined region
  annotates its `fan_in` row with `join` and the row after it with `joined_from`; an open one is
  followed by a synthetic `state: :waiting` `fan_in` row (only when the flow is known). Any other
  `run_branches` value keeps the flat timeline. An in-flight execution whose `run_branch_id` names
  a `:running` branch stays `:active` while a sibling branch parks the run, and a control-node
  `current_node` (`Schemas.Flow.Node.control_types/0`) never gets a synthetic active row — it has
  no job of its own. `branch_bars` maps each `fan_out` key to its latest entry's `branch_bar/1`s.
  `stage_name` comes from the run's own `flow: %{stage: %{name: _}}` (RE426), nil
  whenever that chain is missing or not loaded.
  """

  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.RunBranch

  @type row :: map()
  @type t :: %__MODULE__{}

  @typedoc "How one branch draws in the progress bar (RE440)."
  @type bar() :: :succeeded | :failed | :running | :parked | :queued | :cancelled

  @bar_states [:succeeded, :failed, :running, :parked, :queued, :cancelled]

  defstruct [
    :status,
    :flow_key,
    :stage_name,
    :flow_version,
    :current_node,
    :last_node,
    :started_at,
    :finished_at,
    :breaker_tripped?,
    :tripped_node,
    :tripped_repeats,
    :failure_reason,
    :last_failure_detail,
    :parked_attempt,
    :totals,
    :timeline,
    branch_bars: %{}
  ]

  @doc "Builds the read model from a run (node_executions preloaded) and its flow (or nil)."
  def build(run, flow) do
    nes = Map.get(run, :node_executions) || []

    %__MODULE__{
      status: run.status,
      flow_key: Map.get(run, :flow_key),
      stage_name: stage_name(run),
      flow_version: Map.get(run, :flow_version),
      current_node: Map.get(run, :current_node),
      last_node: Hamaca.Runs.last_node(run, nes),
      started_at: Map.get(run, :started_at),
      finished_at: Map.get(run, :finished_at),
      breaker_tripped?: Hamaca.Runs.breaker_tripped?(run),
      tripped_node: tripped_node(run, nes),
      tripped_repeats: tripped_repeats(run, nes),
      failure_reason: failure_reason(run),
      last_failure_detail: last_failure_detail(nes),
      parked_attempt: parked_attempt(run, nes),
      totals: totals(nes),
      timeline: timeline(run, nes, flow),
      branch_bars: branch_bars(run, nes)
    }
  end

  # ---- branch bars and tallies (RE440): the one partition of branch rows ----

  @doc "The closed set of per-branch progress-bar states, in display order."
  @spec bar_states() :: [bar()]
  def bar_states, do: @bar_states

  @doc """
  How one branch row draws: an open branch by its state, an ended one by its outcome —
  `:cancelled` when a cancel or close ended it with no outcome.
  """
  @spec branch_bar(%{state: atom(), outcome: atom() | nil}) :: bar()
  def branch_bar(%{state: :ended, outcome: nil}), do: :cancelled
  def branch_bar(%{state: :ended, outcome: outcome}), do: outcome
  def branch_bar(%{state: state}), do: state

  @doc """
  Counts branch rows per state (`Schemas.RunBranch.states/0`), plus the ended rows per outcome
  (`succeeded` / `failed`) and the `total`.
  """
  @spec branch_tally([%{state: atom(), outcome: atom() | nil}]) :: %{
          total: non_neg_integer(),
          running: non_neg_integer(),
          queued: non_neg_integer(),
          parked: non_neg_integer(),
          ended: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer()
        }
  def branch_tally(rows) do
    states = Map.new(RunBranch.states(), fn state -> {state, Enum.count(rows, &(&1.state == state))} end)

    outcomes =
      Map.new(RunBranch.outcomes(), fn outcome ->
        {outcome, Enum.count(rows, &(&1.state == :ended and &1.outcome == outcome))}
      end)

    states |> Map.merge(outcomes) |> Map.put(:total, length(rows))
  end

  # Each fan_out key → the bars of its latest entry (highest fan_out_execution_id), by position.
  defp branch_bars(run, nes) do
    key_of = Map.new(nes, &{&1.id, &1.node_key})

    run
    |> branch_rows()
    |> Enum.group_by(& &1.fan_out_execution_id)
    |> Enum.filter(fn {fan_out_id, _rows} -> Map.has_key?(key_of, fan_out_id) end)
    |> Enum.group_by(fn {fan_out_id, _rows} -> Map.fetch!(key_of, fan_out_id) end)
    |> Map.new(fn {key, entries} ->
      {_latest, rows} = Enum.max_by(entries, &elem(&1, 0))
      {key, rows |> Enum.sort_by(& &1.position) |> Enum.map(&branch_bar/1)}
    end)
  end

  # The run's loaded branch rows; nil, absent or not loaded is `[]`.
  defp branch_rows(run) do
    case Map.get(run, :run_branches) do
      branches when is_list(branches) -> branches
      _nil_or_not_loaded -> []
    end
  end

  # ---- stage_name (RE426): the run's own flow's work stage, never the `flow` argument ----

  # Read from `run.flow` (join-preloaded by `Runs.list_runs_for_card/1`). An unloaded association,
  # a deleted flow (nilified `flow_id`) or a flow with no work stage all yield nil; the web layer
  # falls back to `flow_key`.
  defp stage_name(%{flow: %{stage: %{name: name}}}) when is_binary(name), do: name
  defp stage_name(_run), do: nil

  # ---- timeline (was RunComponents.timeline_rows/3; region grouping RE440) ----

  # Executions whose `run_branch_id` names a loaded branch row are lane executions; the rest form
  # the main sequence. Loop rows are computed per sequence (main, then each lane) — over the
  # interleaved whole a branch's loop-back would follow a sibling's execution and lose its chip.
  defp timeline(run, nes, flow) do
    branches = branch_rows(run)
    by_id = Map.new(branches, &{&1.id, &1})
    {lane_nes, main} = Enum.split_with(nes, &Map.has_key?(by_id, Map.get(&1, :run_branch_id)))

    ctx = %{
      run: run,
      nes: nes,
      flow: flow,
      running: running_branch_ids(run),
      entries: Enum.group_by(branches, & &1.fan_out_execution_id),
      lanes: Enum.group_by(lane_nes, &Map.get(&1, :run_branch_id))
    }

    rows = main_rows(main, ctx)
    waiting = for %{kind: :node, state: :waiting, node_key: key} <- rows, do: key

    rows ++ synthetic_active(run, nes, flow) ++ pending_tail(run, nes, flow, waiting)
  end

  defp main_rows(main, ctx) do
    regions = region_entries(main, ctx)
    annotations = join_annotations(regions)

    with_loop_rows(main, ctx, fn ne, index ->
      row = Map.merge(node_row(ne, ctx), Map.get(annotations, index, %{}))

      case Map.fetch(regions, index) do
        {:ok, region} -> [region_row(row, ne, region, ctx) | waiting_fan_in(region)]
        :error -> [row]
      end
    end)
  end

  # Each main-sequence index whose execution opened a region entry → that entry's facts: its
  # branch rows by position, tally, the flow's region (nil without a flow) and the matched
  # `fan_in` execution (rule 7), if any.
  defp region_entries(main, ctx) do
    main
    |> Enum.zip(Enum.drop(main, 1) ++ [nil])
    |> Enum.with_index()
    |> Enum.flat_map(fn {{ne, next}, index} ->
      case Map.get(ctx.entries, ne.id) do
        nil -> []
        rows -> [{index, region_entry(ne, rows, next, ctx.flow)}]
      end
    end)
    |> Map.new()
  end

  defp region_entry(fan_out, rows, next, flow) do
    branches = Enum.sort_by(rows, & &1.position)
    open? = Enum.any?(branches, &(&1.state in RunBranch.open_states()))
    flow_region = flow_region(flow, fan_out.node_key)
    fan_in = if open?, do: nil, else: matched_fan_in(next, flow, flow_region)

    %{branches: branches, open?: open?, tally: branch_tally(branches), region: flow_region, fan_in: fan_in}
  end

  # A joined region's `fan_in` is the next main-sequence execution — when the flow is known, only
  # if its key is the region's `fan_in`.
  defp matched_fan_in(nil, _flow, _region), do: nil
  defp matched_fan_in(next, nil, _region), do: next
  defp matched_fan_in(next, _flow, %{fan_in: fan_in}) when next.node_key == fan_in, do: next
  defp matched_fan_in(_next, _flow, _region), do: nil

  # index → the `join` / `joined_from` keys to merge onto that main-sequence row: the matched
  # `fan_in` sits right after its region's `fan_out`, and the row after it is what joined.
  defp join_annotations(regions) do
    Enum.reduce(regions, %{}, fn
      {index, %{fan_in: %{}, tally: tally}}, acc ->
        acc
        |> Map.update(index + 1, %{join: join(tally)}, &Map.put(&1, :join, join(tally)))
        |> Map.update(index + 2, %{joined_from: tally.total}, &Map.put(&1, :joined_from, tally.total))

      _entry, acc ->
        acc
    end)
  end

  defp join(tally), do: %{total: tally.total, failed: tally.failed}

  defp region_row(header, fan_out, region, ctx) do
    lane_nes = Enum.flat_map(region.branches, &Map.get(ctx.lanes, &1.id, []))

    %{
      kind: :region,
      fan_out_execution_id: fan_out.id,
      header: header,
      open?: region.open?,
      tally: region.tally,
      max_parallel: region.region && region.region.max_parallel,
      duration_s: region_duration_s(fan_out, region.fan_in, lane_nes),
      cost: sum_costs(Enum.map(lane_nes, &Map.get(&1, :cost))),
      lanes: Enum.map(region.branches, &lane(&1, ctx))
    }
  end

  # From the `fan_out`'s start to the matched `fan_in`'s finish, else the latest lane finish.
  defp region_duration_s(fan_out, fan_in, lane_nes) do
    lane_end =
      lane_nes |> Enum.map(&Map.get(&1, :finished_at)) |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)

    finish = (fan_in && Map.get(fan_in, :finished_at)) || lane_end
    started = Map.get(fan_out, :started_at)

    if started && finish, do: DateTime.diff(finish, started)
  end

  defp lane(branch, ctx) do
    rows =
      case Map.get(ctx.lanes, branch.id, []) do
        [] when branch.state == :queued ->
          [synthetic_row(branch.branch, :queued, type_tag(branch.branch, ctx.flow))]

        nes ->
          with_loop_rows(nes, ctx, fn ne, _index -> [node_row(ne, ctx)] end)
      end

    %{branch: branch.branch, position: branch.position, state: branch.state, outcome: branch.outcome, rows: rows}
  end

  # An open region whose flow names its `fan_in` is followed by that `fan_in`, waiting.
  defp waiting_fan_in(%{open?: true, region: %{fan_in: fan_in}, tally: tally}) when is_binary(fan_in),
    do: [synthetic_row(fan_in, :waiting, :fan_in, %{join: join(tally)})]

  defp waiting_fan_in(_region), do: []

  # One sequence's rows: each execution's rows (from `fun`), preceded by a `:loop` row when it
  # re-enters after the sequence's previous execution failed.
  defp with_loop_rows(seq, ctx, fun) do
    seq
    |> Enum.zip([nil | seq])
    |> Enum.with_index()
    |> Enum.flat_map(fn {{ne, prev}, index} -> loop_row(ne, prev, ctx) ++ fun.(ne, index) end)
  end

  defp loop_row(ne, prev, ctx) do
    if ne.attempt > 1 and prev != nil and prev.outcome == :failed do
      [
        %{
          kind: :loop,
          from_node: prev.node_key,
          to_node: ne.node_key,
          attempt: spent_attempt(ne, ctx.nes),
          max_loops: max_loops(prev, ctx.flow)
        }
      ]
    else
      []
    end
  end

  defp flow_region(%Flow{} = flow, key), do: Flow.region(flow, key)
  defp flow_region(_flow, _key), do: nil

  defp node_row(ne, ctx) do
    %{
      kind: :node,
      node_key: ne.node_key,
      attempt: spent_attempt(ne, ctx.nes),
      state: branch_row_state(ne, ctx.run, ctx.running),
      resumed?: resumed?(ne, ctx.nes),
      steered?: ne.outcome == :steered,
      partial?: ne.outcome == :partial,
      type: type_tag(ne.node_key, ctx.flow),
      detail: Map.get(ne, :detail),
      cost: Map.get(ne, :cost),
      duration_s: ne_duration_s(ne),
      join: nil,
      joined_from: nil
    }
  end

  # A node row no execution backs: the between-nodes active row, a queued branch's placeholder,
  # an open region's waiting `fan_in`.
  defp synthetic_row(node_key, state, type, extra \\ %{}) do
    Map.merge(
      %{
        kind: :node,
        node_key: node_key,
        attempt: 1,
        state: state,
        resumed?: false,
        steered?: false,
        partial?: false,
        type: type,
        detail: nil,
        cost: nil,
        duration_s: nil,
        join: nil,
        joined_from: nil
      },
      extra
    )
  end

  # RE267: the attempt number a human reads. A `:blocked` attempt spent no retry — RE308 parks it,
  # RE267 requeues it at attempt +1 — so earlier blocked attempts of the same {node, visit} are not
  # counted. Without this a node that waited out a usage limit twice read "attempt 3" on its first
  # real run, and an escalation said "failed after 3 attempts" for two. A `:steered` attempt (RE358)
  # is a human restart, not a retry, so it is not counted either.
  defp spent_attempt(ne, nes) do
    unspent = [:blocked | NodeExecution.server_only_outcomes()]

    waits =
      Enum.count(nes, fn other ->
        other.node_key == ne.node_key and Map.get(other, :visit) == Map.get(ne, :visit) and
          other.attempt < ne.attempt and other.outcome in unspent
      end)

    max(ne.attempt - waits, 1)
  end

  # ---- run_branches (RE437): the ids of the branches still running ----

  defp running_branch_ids(run) do
    case Map.get(run, :run_branches) do
      branches when is_list(branches) -> for %{state: :running, id: id} <- branches, into: MapSet.new(), do: id
      _nil_or_not_loaded -> MapSet.new()
    end
  end

  # An in-flight branch execution keeps running while a sibling branch parks the run; every other
  # row reads `row_state/2`.
  defp branch_row_state(%{outcome: nil} = ne, %{status: :parked} = run, running) do
    if MapSet.member?(running, Map.get(ne, :run_branch_id)), do: :active, else: row_state(ne, run)
  end

  defp branch_row_state(ne, run, _running), do: row_state(ne, run)

  # ---- row_state (was RunComponents.row_state/2), verbatim ----

  defp row_state(%{outcome: :succeeded}, _run), do: :done
  defp row_state(%{outcome: :partial}, _run), do: :done
  defp row_state(%{outcome: :failed}, _run), do: :failed
  defp row_state(%{outcome: :needs_input}, _run), do: :paused
  defp row_state(%{outcome: :blocked}, _run), do: :paused
  defp row_state(%{outcome: :steered}, _run), do: :steered
  defp row_state(%{outcome: nil}, %{status: :running}), do: :active
  defp row_state(%{outcome: nil}, %{status: :parked}), do: :paused
  defp row_state(%{outcome: nil}, %{status: :failed}), do: :stopped
  defp row_state(%{outcome: nil}, _run), do: :cancelled

  # ---- resumed? (was RunComponents.resumed?/2) ----

  # A needs-input re-entry resumes the session; so does a Steer now restart (RE358), but only when
  # the stopped attempt had captured a session id — without one the restart starts fresh.
  defp resumed?(%{attempt: attempt, node_key: node_key}, nes) when attempt > 1 do
    nes
    |> Enum.filter(&(&1.node_key == node_key and &1.attempt < attempt))
    |> List.last()
    |> case do
      %{outcome: :needs_input} -> true
      %{outcome: :steered} = steered -> not is_nil(Map.get(steered, :session_id))
      _other -> false
    end
  end

  defp resumed?(_ne, _nes), do: false

  # ---- loop max_loops (was baked into RunComponents.loop_text/3) ----

  defp max_loops(prev, %Flow{edges: edges}) do
    edge = Enum.find(edges, &(&1.from == prev.node_key and &1.on == :failed and &1.max_loops))
    edge && edge.max_loops
  end

  defp max_loops(_prev, _flow), do: nil

  # ---- type_tag (was RunComponents.type_tag/2), verbatim ----

  defp type_tag(node_key, %Flow{nodes: nodes}), do: Enum.find_value(nodes, fn n -> n.key == node_key && n.type end)

  defp type_tag(_node_key, _flow), do: nil

  # ---- synthetic_active (was RunComponents.synthetic_active/2), adjusted to the node-row shape ----

  defp synthetic_active(%{status: :running, current_node: node_key}, nes, flow) when is_binary(node_key) do
    if Enum.any?(nes, &is_nil(&1.outcome)) or type_tag(node_key, flow) in Flow.Node.control_types() do
      []
    else
      [synthetic_row(node_key, :active, nil)]
    end
  end

  defp synthetic_active(_run, _nes, _flow), do: []

  # ---- pending_tail (was RunComponents.pending_tail/3), returns node keys ----

  # `waiting` are the keys already rendered as a synthetic `:waiting` `fan_in` row (RE440).
  defp pending_tail(%{status: status} = run, nes, %Flow{} = flow, waiting) do
    if status in Schemas.Run.active_statuses() do
      shown = MapSet.new(Enum.map(nes, & &1.node_key) ++ waiting)

      remaining =
        flow
        |> Hamaca.Runs.happy_path()
        |> Enum.reject(&(MapSet.member?(shown, &1) or &1 == Map.get(run, :current_node)))

      if remaining == [], do: [], else: [%{kind: :pending, nodes: remaining}]
    else
      []
    end
  end

  defp pending_tail(_run, _nes, _flow, _waiting), do: []

  # ---- totals (was CoreComponents.run_totals/1) ----

  defp totals(nes) do
    %{
      duration_s: nes |> Enum.map(&ne_duration_s/1) |> Enum.reject(&is_nil/1) |> Enum.sum(),
      cost: sum_costs(Enum.map(nes, &Map.get(&1, :cost))),
      nodes: nes |> Enum.map(& &1.node_key) |> Enum.uniq() |> length(),
      attempts: length(nes)
    }
  end

  defp sum_costs(costs) do
    case Enum.reject(costs, &is_nil/1) do
      [] -> nil
      present -> Enum.reduce(present, Decimal.new(0), &Decimal.add/2)
    end
  end

  # ---- duration source (was RunComponents.ne_duration_s/1), verbatim ----

  defp ne_duration_s(%{duration_s: seconds}) when not is_nil(seconds), do: seconds
  defp ne_duration_s(%{started_at: s, finished_at: f}) when not is_nil(s) and not is_nil(f), do: DateTime.diff(f, s)
  defp ne_duration_s(_ne), do: nil

  # ---- failure forensics (was RunComponents.last_failure_detail/1, failure_reason/1,
  #      tripped_node/2, parked_attempt/2), verbatim ----

  # The failure that stopped or parked the run — see NodeExecution.failure_outcomes/0 for why.
  defp last_failure_detail(nes) do
    nes
    |> Enum.filter(&(&1.outcome in NodeExecution.failure_outcomes()))
    |> List.last()
    |> then(&(&1 && &1.detail))
  end

  defp failure_reason(%{failure_detail: reason}) when is_binary(reason), do: reason
  defp failure_reason(_run), do: "The run stopped before reaching the end of the flow."

  defp tripped_node(run, nes) do
    nes
    |> Enum.filter(&(&1.outcome == :failed))
    |> List.last()
    |> case do
      %{node_key: node_key} -> node_key
      _other -> Map.get(run, :current_node)
    end
  end

  defp tripped_repeats(run, nes) do
    tripped = tripped_node(run, nes)
    Enum.count(nes, &(&1.node_key == tripped and &1.outcome == :failed))
  end

  defp parked_attempt(%{current_node: nil}, _nes), do: 1

  defp parked_attempt(%{current_node: node_key}, nes) do
    nes
    |> Enum.filter(&(&1.node_key == node_key))
    |> Enum.map(&spent_attempt(&1, nes))
    |> case do
      [] -> 1
      attempts -> Enum.max(attempts)
    end
  end

  defp parked_attempt(_run, _nes), do: 1
end
