defmodule Relay.ValueStream do
  @moduledoc """
  Level-1 value-stream derivation (RE146): turns a card's activity log and its runs' node
  executions into **spans** — the card's time from the board's stream start (`Next up` on RE)
  to `Done`, split by stream state and by who holds the baton (`batons/0`). The data source
  for the card stream map (RE347); nothing here renders. `stream_summary/2` averages spans over
  a set of done cards; `flow_agent_secs/3` reconciles agent time with Flow Metrics.

  Read-only: no processes, no PubSub, no writes. Everything is derived from durable history —
  `:moved` / `:approved` / `:rejected` rows (with `from_stage_id` / `to_stage_id` meta),
  `:needs_input` → `:input_answered` parks, and `node_executions` — so nothing new is tracked.

  **The span invariant.** A card's spans tile `[started_at, done_at]` (or `now` for an
  unfinished card) with no gaps and no overlaps: `Σ span.secs == lead_secs`, and for every
  span `agent + human + nobody == secs`.

  **Gate attribution.** A decision belongs to the gate the card just left — the
  `from_stage_id` of the latest `:moved` row before it — or, for an in-place approve, to its
  own stage. (`Relay.Cards.reject/3` logs the gate's *main* stage as `from_stage_id`, so the
  decision row's own `from_stage_id` is not the gate.)

  **Known approximations.** `ai_enabled` is read from the stage as it is *now* (the flag has
  no history). Node roles come from the board's *current* flow for a run's `flow_key`
  (`Schemas.Flow.node_roles/1`); a node key missing from it is not value-add.
  """

  use Boundary, deps: [Relay.Boards, Relay.Cards, Relay.Flows, Relay.Repo, Relay.Runs, Schemas]

  import Ecto.Query

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Flows
  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Activity
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.Run
  alias Schemas.Stage

  @kinds [:queue, :flow, :gate, :done]
  @batons [:agent, :human, :nobody]
  @default_last 20
  @decision_types [:approved, :rejected]
  @history_types [:moved, :needs_input, :input_answered | @decision_types]

  @doc "The closed set of stream-state kinds. Defined once; RE347 reads it."
  def kinds, do: @kinds

  @doc "The closed set of baton holders. Defined once; RE347 reads it."
  def batons, do: @batons

  @doc """
  The board's ordered stream states, `[%{stage_id, name, kind}]`, from the **stream start**
  through the terminal stage (`Relay.Boards.terminal_stage/1`), each main stage followed by its
  substages (review, then done).

  The stream start is the last `:queue` main stage before the first
  `Schemas.Stage.work_types/0` main stage (`Next up` on RE), else that first work stage, else
  the first main stage. `kind` comes from `Stage.type`: `:queue` → `:queue`, work/planning →
  `:flow`, `:review` → `:gate`, the terminal stage → `:done`, and a mid-board `:done` substage
  → `:queue` (the card is parked; nobody holds it).

  States come from the flows' triggers: an `ai_enabled` work/planning main stage that no
  **enabled** flow works in (`works_in_stage_id`) is left out, substages included (RE's
  `Deploy`). No agent can hold the baton there, so time in it counts as off-stream (a `:queue`
  span nobody holds). A board with no enabled flows has no triggers to read, so every work
  stage stays in. A work stage that isn't `ai_enabled` is manual work and always stays in.
  """
  def stream_states(board_id) when is_integer(board_id) do
    build_states(load_stages(board_id), flow_worked_stage_ids(board_id))
  end

  @doc """
  One card's level-1 stream, or `nil` if it never entered a stream state.

  - `started_at` — its first entry into any stream state.
  - `done_at` — its last entry into the terminal stage, or a later in-place approve there;
    `nil` unless `Relay.Cards.done?/2`.
  - `spans` — one per stay between the two (or to now), each
    `%{stage_id, name, kind, visit, entered_at, left_at, secs, baton, value_add_secs}`. A stay
    in an off-stream or deleted stage is a `:queue` span nobody holds.
  - `lead_secs`, `baton_secs` (summed over spans), `value_add_secs` (agent time on `:do`
    nodes), `flow_efficiency` (`value_add_secs / lead_secs`, nil for a zero lead), `cost` (a
    Decimal over every execution of every run of the card), and `gates` (one
    `%{stage_id, approved, rejected}` per `:gate` stream state).
  """
  def card_stream(%Card{} = card) do
    ctx = board_context(card.board_id)
    history = [card.id] |> load_history() |> Map.get(card.id, [])
    execs = [card.id] |> load_executions() |> Map.get(card.id, [])
    build_stream(card, ctx, history, execs, now())
  end

  @doc "How many done cards `stream_summary/2` averages when no `:window` is given."
  def default_last, do: @default_last

  @doc """
  The level-1 stream averaged over a set of the board's done cards — archived ones included,
  because they shipped — newest `done_at` first. `opts`: `last: n` (default `default_last/0`)
  or `window: w` (validated against `Relay.Runs.metric_windows/0` via
  `Relay.Runs.metric_window_since/1`; an unknown window falls back to the default, as Flow
  Metrics does), which keeps cards whose `done_at` falls inside it.

  Returns `%{cards, states, mean_lead_secs, median_lead_secs, baton_secs, flow_efficiency,
  mean_cost, outside_secs}`. Each state (in `stream_states/1` order) is `%{stage_id, name,
  kind, mean_secs, mean_visits, mean_baton, approve_rate}`; `approve_rate` is set for gates
  only — Σapproved / (Σapproved + Σrejected), `nil` with no decisions. Means are per state so
  they add up: `Σ states.mean_secs + outside_secs == mean_lead_secs` (`outside_secs` is time
  in off-stream or deleted stages). `flow_efficiency` is Σvalue-add / Σlead.
  """
  def stream_summary(board_id, opts \\ []) when is_integer(board_id) do
    ctx = board_context(board_id)
    selected = selected_done_cards(board_id, ctx, opts)
    execs = selected |> Enum.map(fn {card, _rows, _done_at} -> card.id end) |> load_executions()
    now = now()

    selected
    |> Enum.map(fn {card, rows, _done_at} -> build_stream(card, ctx, rows, Map.get(execs, card.id, []), now) end)
    |> Enum.reject(&is_nil/1)
    |> summarize(ctx)
  end

  @doc """
  Agent seconds on `flow_key` for a card set — `card_id:` for one card, else the same
  `last:` / `window:` set as `stream_summary/2` — reading the same
  `node_executions.started_at/finished_at` columns `Relay.Runs.node_metrics_for_flow/2` sums
  (finished executions only). Per card it is the **union** of the intervals, so it equals Flow
  Metrics' `Σ duration_total` when a card's executions don't overlap and can only be smaller,
  never larger, when they do. Exists for the criterion-4 reconciliation; it is not another
  metric.
  """
  def flow_agent_secs(board_id, flow_key, opts \\ []) when is_integer(board_id) and is_binary(flow_key) do
    card_ids =
      case Keyword.get(opts, :card_id) do
        nil ->
          board_id
          |> selected_done_cards(board_context(board_id), opts)
          |> Enum.map(fn {card, _rows, _done_at} -> card.id end)

        card_id ->
          [card_id]
      end

    from(ne in NodeExecution,
      join: r in Run,
      on: r.id == ne.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where:
        c.board_id == ^board_id and r.flow_key == ^flow_key and c.id in ^card_ids and
          not is_nil(ne.started_at) and not is_nil(ne.finished_at),
      select: {c.id, ne.started_at, ne.finished_at}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_id, started, finished} -> {unix(started), unix(finished)} end)
    |> Enum.map(fn {_id, intervals} -> intervals |> union() |> total() end)
    |> Enum.sum()
  end

  # ── board context ────────────────────────────────────────────────────────────

  defp board_context(board_id) do
    stages = load_stages(board_id)
    states = build_states(stages, flow_worked_stage_ids(board_id))

    %{
      stages: stages,
      stages_by_id: Map.new(stages, &{&1.id, &1}),
      names: display_names(stages),
      states: states,
      state_by_id: Map.new(states, &{&1.stage_id, &1}),
      terminal: Boards.terminal_stage(stages),
      roles: %Board{id: board_id} |> Flows.list_flows() |> Map.new(&{&1.key, Flow.node_roles(&1)})
    }
  end

  defp load_stages(board_id), do: Boards.list_stages(%Board{id: board_id})

  # Stage ids an enabled flow works in, or `nil` when the board has no enabled flows.
  defp flow_worked_stage_ids(board_id) do
    case Flows.list_enabled_flows(%Board{id: board_id}) do
      [] -> nil
      flows -> MapSet.new(flows, & &1.works_in_stage_id)
    end
  end

  defp build_states(stages, worked_ids) do
    case Boards.terminal_stage(stages) do
      nil ->
        []

      terminal ->
        names = display_names(stages)
        mains = stages |> Enum.filter(&is_nil(&1.parent_id)) |> Enum.sort_by(& &1.position)
        subs = stages |> Enum.reject(&is_nil(&1.parent_id)) |> Enum.group_by(& &1.parent_id)

        mains
        |> Enum.drop(stream_start_index(mains))
        |> Enum.filter(&in_stream?(&1, worked_ids))
        |> Enum.flat_map(&with_substages(&1, subs, terminal))
        |> Enum.map(&%{stage_id: &1.id, name: Map.fetch!(names, &1.id), kind: kind(&1, terminal)})
    end
  end

  defp with_substages(%Stage{id: id} = terminal, _subs, %Stage{id: id}), do: [terminal]

  defp with_substages(%Stage{} = main, subs, _terminal) do
    [main | subs |> Map.get(main.id, []) |> Enum.sort_by(&substage_order/1)]
  end

  defp in_stream?(_stage, nil), do: true

  defp in_stream?(%Stage{ai_enabled: true, type: type} = stage, worked_ids) do
    type not in Stage.work_types() or MapSet.member?(worked_ids, stage.id)
  end

  defp in_stream?(%Stage{}, _worked_ids), do: true

  defp substage_order(%Stage{type: :review}), do: 0
  defp substage_order(%Stage{}), do: 1

  defp stream_start_index(mains) do
    case Enum.find_index(mains, &(&1.type in Stage.work_types())) do
      nil -> 0
      first_work -> last_queue_before(mains, first_work) || first_work
    end
  end

  defp last_queue_before(mains, index) do
    mains
    |> Enum.take(index)
    |> Enum.with_index()
    |> Enum.filter(fn {stage, _i} -> stage.type == :queue end)
    |> Enum.map(fn {_stage, i} -> i end)
    |> List.last()
  end

  defp kind(%Stage{id: id}, %Stage{id: id}), do: :done
  defp kind(%Stage{type: :review}, _terminal), do: :gate
  defp kind(%Stage{type: type}, _terminal), do: if(type in Stage.work_types(), do: :flow, else: :queue)

  defp display_names(stages) do
    by_id = Map.new(stages, &{&1.id, &1})
    Map.new(stages, &{&1.id, Boards.stage_display_name(&1, Map.get(by_id, &1.parent_id, &1))})
  end

  # ── loading (one query each, any number of cards) ───────────────────────────

  defp load_history(card_ids) do
    from(a in Activity,
      where: a.card_id in ^card_ids and a.type in ^@history_types,
      order_by: [asc: a.id],
      select: %{card_id: a.card_id, type: a.type, meta: a.meta, at: a.inserted_at}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.card_id)
  end

  defp load_executions(card_ids) do
    from(ne in NodeExecution,
      join: r in Run,
      on: r.id == ne.run_id,
      where: r.card_id in ^card_ids,
      order_by: [asc: ne.id],
      select: %{
        card_id: r.card_id,
        flow_key: r.flow_key,
        node_key: ne.node_key,
        started_at: ne.started_at,
        finished_at: ne.finished_at,
        cost: ne.cost
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.card_id)
  end

  # ── one card ─────────────────────────────────────────────────────────────────

  defp build_stream(card, ctx, history, execs, now) do
    {stays, decisions} = fold_history(card, history)

    with start when is_integer(start) <- stream_start(stays, ctx) do
      started_at = Enum.at(stays, start).at
      {span_stays, done_at, in_place?} = stream_window(card, ctx, stays, decisions, start)
      end_at = done_at || now

      clocks = %{
        agent: execs |> exec_intervals(end_at) |> union(),
        parks: park_intervals(history, end_at),
        value: execs |> Enum.filter(&do_node?(&1, ctx.roles)) |> exec_intervals(end_at) |> union()
      }

      spans = build_spans(span_stays, end_at, in_place?, ctx, clocks)
      lead = unix(end_at) - unix(started_at)
      value_add = spans |> Enum.map(& &1.value_add_secs) |> Enum.sum()

      %{
        card_id: card.id,
        started_at: started_at,
        done_at: done_at,
        spans: spans,
        lead_secs: lead,
        baton_secs: Map.new(@batons, fn b -> {b, spans |> Enum.map(& &1.baton[b]) |> Enum.sum()} end),
        value_add_secs: value_add,
        flow_efficiency: if(lead == 0, do: nil, else: value_add / lead),
        cost: Enum.reduce(execs, Decimal.new(0), &Decimal.add(&2, &1.cost || Decimal.new(0))),
        gates: gate_counts(ctx, decisions, started_at, end_at)
      }
    end
  end

  # Stays (one per entry into a stage, in order) and gate decisions from the card's history.
  defp fold_history(card, history) do
    initial = initial_stay(card, Enum.filter(history, &(&1.type == :moved)))
    {stays, decisions, _last_from} = Enum.reduce(history, {[initial], [], nil}, &fold_row/2)
    {Enum.reverse(stays), Enum.reverse(decisions)}
  end

  defp initial_stay(card, [first | _]),
    do: %{stage_id: first.meta["from_stage_id"], snapshot: first.meta["from_stage"], at: card.inserted_at}

  defp initial_stay(card, []), do: %{stage_id: card.stage_id, snapshot: nil, at: card.inserted_at}

  defp fold_row(%{type: :moved, meta: meta, at: at}, {stays, decisions, _last_from}) do
    stay = %{stage_id: meta["to_stage_id"], snapshot: meta["to_stage"], at: at}
    {[stay | stays], decisions, meta["from_stage_id"]}
  end

  defp fold_row(%{type: type, meta: meta, at: at}, {stays, decisions, last_from}) when type in @decision_types do
    in_place? = type == :approved and meta["from_stage_id"] == meta["to_stage_id"]
    gate_id = if in_place?, do: meta["from_stage_id"], else: last_from
    decision = %{type: type, gate_id: gate_id, in_place?: in_place?, at: at}
    {stays, [decision | decisions], last_from}
  end

  defp fold_row(_park, acc), do: acc

  defp stream_start(stays, ctx), do: Enum.find_index(stays, &Map.has_key?(ctx.state_by_id, &1.stage_id))

  # {stays that become spans, done_at, whether the last stay is an in-place-approved terminal gate}
  defp stream_window(card, ctx, stays, decisions, start) do
    last = if Cards.done?(card, ctx.stages), do: last_index(stays, &(&1.stage_id == ctx.terminal.id))

    case last do
      nil -> {Enum.drop(stays, start), nil, false}
      last -> done_window(stays, decisions, start, last)
    end
  end

  defp done_window(stays, decisions, start, last) do
    %{stage_id: terminal_id, at: entered} = Enum.at(stays, last)

    approval =
      decisions
      |> Enum.filter(&(&1.in_place? and &1.gate_id == terminal_id and DateTime.compare(&1.at, entered) != :lt))
      |> List.last()

    case approval do
      nil -> {Enum.slice(stays, start..(last - 1)//1), entered, false}
      %{at: approved_at} -> {Enum.slice(stays, start..last//1), approved_at, true}
    end
  end

  defp last_index(list, fun) do
    case list |> Enum.with_index() |> Enum.filter(fn {x, _i} -> fun.(x) end) |> List.last() do
      nil -> nil
      {_x, i} -> i
    end
  end

  defp build_spans(stays, end_at, in_place?, ctx, clocks) do
    lefts = stays |> Enum.drop(1) |> Enum.map(& &1.at) |> Kernel.++([end_at])
    last = length(stays) - 1

    {spans, _visits} =
      stays
      |> Enum.zip(lefts)
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {{stay, left_at}, i}, visits ->
        key = stay.stage_id || stay.snapshot
        visits = Map.update(visits, key, 1, &(&1 + 1))
        kind = if in_place? and i == last, do: :gate, else: span_kind(stay, ctx)
        {span(stay, left_at, kind, visits[key], ctx, clocks), visits}
      end)

    spans
  end

  defp span_kind(stay, ctx) do
    case Map.get(ctx.state_by_id, stay.stage_id) do
      nil -> :queue
      state -> state.kind
    end
  end

  defp span(stay, left_at, kind, visit, ctx, clocks) do
    a = unix(stay.at)
    b = unix(left_at)
    {baton, value_add} = split(kind, Map.get(ctx.stages_by_id, stay.stage_id), a, b, clocks)

    %{
      stage_id: stay.stage_id,
      name: Map.get(ctx.names, stay.stage_id) || stay.snapshot,
      kind: kind,
      visit: visit,
      entered_at: stay.at,
      left_at: left_at,
      secs: b - a,
      baton: baton,
      value_add_secs: value_add
    }
  end

  # Decision 3: inside an ai_enabled flow stage the agent holds the baton for the union of the
  # card's executions, a human for its parks (minus agent overlap), nobody for the rest.
  defp split(:flow, %Stage{ai_enabled: true}, a, b, clocks) do
    agent = clocks.agent |> clip(a, b) |> total()
    busy = (clocks.agent ++ clocks.parks) |> union() |> clip(a, b) |> total()
    value = clocks.value |> clip(a, b) |> total()
    {%{agent: agent, human: busy - agent, nobody: b - a - busy}, value}
  end

  defp split(kind, _stage, a, b, _clocks) when kind in [:flow, :gate], do: {%{agent: 0, human: b - a, nobody: 0}, 0}
  defp split(_kind, _stage, a, b, _clocks), do: {%{agent: 0, human: 0, nobody: b - a}, 0}

  defp do_node?(exec, roles), do: get_in(roles, [exec.flow_key, exec.node_key]) == :do

  defp exec_intervals(execs, end_at) do
    for %{started_at: %DateTime{} = started} = exec <- execs,
        do: {unix(started), unix(exec.finished_at || end_at)}
  end

  defp park_intervals(history, end_at) do
    {closed, open_at} =
      Enum.reduce(history, {[], nil}, fn
        %{type: :needs_input, at: at}, {acc, nil} -> {acc, at}
        %{type: :input_answered, at: at}, {acc, open} when not is_nil(open) -> {[{unix(open), unix(at)} | acc], nil}
        _row, acc -> acc
      end)

    if open_at, do: [{unix(open_at), unix(end_at)} | closed], else: closed
  end

  defp gate_counts(ctx, decisions, started_at, end_at) do
    counted =
      Enum.filter(decisions, &(DateTime.compare(&1.at, started_at) != :lt and DateTime.compare(&1.at, end_at) != :gt))

    for %{kind: :gate, stage_id: id} <- ctx.states do
      mine = Enum.filter(counted, &(&1.gate_id == id))

      %{
        stage_id: id,
        approved: Enum.count(mine, &(&1.type == :approved)),
        rejected: Enum.count(mine, &(&1.type == :rejected))
      }
    end
  end

  # ── averaged ────────────────────────────────────────────────────────────────

  # [{card, history_rows, done_at}] — the board's done cards (archived included), newest
  # done_at first, scoped by `last:` or `window:`.
  defp selected_done_cards(board_id, ctx, opts) do
    cards = done_cards(board_id, ctx)
    history = cards |> Enum.map(& &1.id) |> load_history()

    cards
    |> Enum.map(fn card ->
      rows = Map.get(history, card.id, [])
      {card, rows, done_at(card, ctx, rows)}
    end)
    |> Enum.reject(fn {_card, _rows, done_at} -> is_nil(done_at) end)
    |> Enum.sort_by(fn {_card, _rows, done_at} -> done_at end, {:desc, DateTime})
    |> apply_scope(opts)
  end

  defp done_cards(_board_id, %{terminal: nil}), do: []

  defp done_cards(board_id, %{terminal: terminal} = ctx) do
    from(c in Card, where: c.board_id == ^board_id and c.stage_id == ^terminal.id)
    |> Repo.all()
    |> Enum.filter(&Cards.done?(&1, ctx.stages))
  end

  defp done_at(card, ctx, rows) do
    {stays, decisions} = fold_history(card, rows)

    with start when is_integer(start) <- stream_start(stays, ctx) do
      {_stays, done_at, _in_place?} = stream_window(card, ctx, stays, decisions, start)
      done_at
    end
  end

  defp apply_scope(entries, opts) do
    case Keyword.fetch(opts, :window) do
      {:ok, window} -> since(entries, Runs.metric_window_since(window))
      :error -> Enum.take(entries, last_n(opts))
    end
  end

  defp since(entries, nil), do: entries

  defp since(entries, cutoff),
    do: Enum.filter(entries, fn {_card, _rows, done_at} -> DateTime.compare(done_at, cutoff) != :lt end)

  defp last_n(opts) do
    case Keyword.get(opts, :last) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_last
    end
  end

  defp summarize(streams, ctx) do
    n = length(streams)
    spans = Enum.flat_map(streams, & &1.spans)
    leads = Enum.map(streams, & &1.lead_secs)
    total_lead = Enum.sum(leads)
    value_add = streams |> Enum.map(& &1.value_add_secs) |> Enum.sum()

    %{
      cards: n,
      states: Enum.map(ctx.states, &state_summary(&1, spans, streams, n)),
      mean_lead_secs: mean(total_lead, n),
      median_lead_secs: median(leads),
      baton_secs: Map.new(@batons, fn b -> {b, streams |> Enum.map(& &1.baton_secs[b]) |> Enum.sum() |> mean(n)} end),
      flow_efficiency: if(total_lead == 0, do: nil, else: value_add / total_lead),
      mean_cost: mean_cost(streams, n),
      outside_secs:
        spans
        |> Enum.reject(&Map.has_key?(ctx.state_by_id, &1.stage_id))
        |> Enum.map(& &1.secs)
        |> Enum.sum()
        |> mean(n)
    }
  end

  defp state_summary(state, spans, streams, n) do
    mine = Enum.filter(spans, &(&1.stage_id == state.stage_id))

    %{
      stage_id: state.stage_id,
      name: state.name,
      kind: state.kind,
      mean_secs: mine |> Enum.map(& &1.secs) |> Enum.sum() |> mean(n),
      mean_visits: mean(length(mine), n),
      mean_baton: Map.new(@batons, fn b -> {b, mine |> Enum.map(& &1.baton[b]) |> Enum.sum() |> mean(n)} end),
      approve_rate: approve_rate(state, streams)
    }
  end

  defp approve_rate(%{kind: :gate, stage_id: id}, streams) do
    gates = streams |> Enum.flat_map(& &1.gates) |> Enum.filter(&(&1.stage_id == id))
    approved = gates |> Enum.map(& &1.approved) |> Enum.sum()
    decided = approved + (gates |> Enum.map(& &1.rejected) |> Enum.sum())
    if decided == 0, do: nil, else: approved / decided
  end

  defp approve_rate(_state, _streams), do: nil

  defp mean(_total, 0), do: 0.0
  defp mean(total, n), do: total / n

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp mean_cost(_streams, 0), do: nil

  defp mean_cost(streams, n) do
    streams
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.cost))
    |> Decimal.div(n)
    |> Decimal.round(2)
  end

  # ── interval arithmetic (unix seconds) ──────────────────────────────────────

  defp union(intervals) do
    intervals
    |> Enum.reject(fn {s, e} -> e <= s end)
    |> Enum.sort()
    |> Enum.reduce([], fn
      {s, e}, [{ps, pe} | rest] when s <= pe -> [{ps, max(pe, e)} | rest]
      interval, acc -> [interval | acc]
    end)
    |> Enum.reverse()
  end

  defp clip(intervals, a, b) do
    Enum.flat_map(intervals, fn {s, e} ->
      {s, e} = {max(s, a), min(e, b)}
      if e > s, do: [{s, e}], else: []
    end)
  end

  defp total(intervals), do: intervals |> Enum.map(fn {s, e} -> e - s end) |> Enum.sum()

  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
