defmodule Relay.Runs do
  @moduledoc """
  The Runs engine (ADR 0006 card 02): executes a `Schemas.Flow` graph
  against a card as a supervised, Postgres-backed state machine. A run
  points at the LIVE flow row (no snapshot — RLY-152); every state
  transition persists run/execution/job rows in a transaction FIRST, then
  broadcasts on `board:<id>:runs`, then dispatches — so Postgres is always
  the checkpoint of record.

  All card writes go through `Relay.Cards`' public API (`move_card/4`,
  `set_status/3`, `request_input/3`), so ADR 0003 snapping and ADR 0004
  claiming apply automatically — the engine never re-implements card-state
  rules. Node execution goes through the `Relay.Runs.Dispatcher`
  behaviour, resolved through `Relay.Runs.Instance` — `config :relay, :runs_dispatcher` in
  production, a per-test instance under test (ADR 0009) — so the whole engine is
  provable with a fake executor before cards 04/05 exist.
  """

  use Boundary,
    deps: [
      Relay.Activity,
      Relay.Boards,
      Relay.Cards,
      Relay.Events,
      Relay.Flows,
      Relay.Repo,
      Relay.Scaffold,
      Schemas
    ],
    exports: [Supervisor, Capacity, RunDetail, SchedulerSupervisor]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs.Audit
  alias Relay.Runs.Capacity
  alias Relay.Runs.Engine
  alias Relay.Runs.Instance
  alias Relay.Runs.PlanTasks
  alias Relay.Runs.Policy
  alias Relay.Runs.Preflight
  alias Relay.Runs.RunServer
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.Server, as: SchedulerServer
  alias Relay.Runs.Transitions
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Executor
  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.Stage
  alias Schemas.SubTask

  @pubsub Relay.PubSub
  @append_index 1_000_000

  ## Reads

  @doc "The run with `id`; raises when absent."
  def get_run!(id), do: Repo.get!(Run, id)

  @doc "The run with `id`, or nil."
  def get_run(id), do: Repo.get(Run, id)

  @doc """
  The board's active runs (`status in Run.active_statuses()`) as `Snapshot.run`
  maps — the shape `Relay.Runs.Scheduler.plan/1` reads. `isolation` comes from
  the live flow row (left-joined, so a run whose flow was deleted still appears
  and excludes its card from fresh pulls, with `isolation: nil` → undispatchable
  until the run fails on its next transition).

  `pinned_executor_name` is the run's persisted exclusive-affinity pin (RLY-199,
  set on claim, kept through an `:executor_gone` park, cleared by a human baton);
  `pinned_executor_id` resolves it to that board's durable executor row id — the
  key `Relay.Runs.Capacity` is keyed by — via a left join on `(board_id, name)`
  (nil when unpinned or the executor row is absent). `Scheduler.resume_runs/2`
  targets `{:pinned, pinned_executor_id}` for an exclusive resume, so an
  `:exclusive` flow's parked run now resumes on the machine holding its worktree.
  """
  def active_runs(board_id) do
    Repo.all(
      from(r in Run,
        join: c in Card,
        on: c.id == r.card_id,
        left_join: f in Flow,
        on: f.id == r.flow_id,
        left_join: e in Executor,
        on: e.board_id == c.board_id and e.name == r.pinned_executor_name,
        where: c.board_id == ^board_id and r.status in ^Run.active_statuses(),
        select: %{
          id: r.id,
          card_id: r.card_id,
          status: r.status,
          flow_key: r.flow_key,
          isolation: f.isolation,
          parked_reason: r.parked_reason,
          pinned_executor_name: r.pinned_executor_name,
          pinned_executor_id: e.id
        }
      )
    )
  end

  @doc "The card's single active (running or parked) run, or nil — backed by the partial unique index."
  def active_run(%Card{id: card_id}) do
    Repo.one(from r in Run, where: r.card_id == ^card_id and r.status in ^Run.active_statuses())
  end

  @doc "All of the card's runs, newest first."
  def list_runs(%Card{id: card_id}) do
    Repo.all(from r in Run, where: r.card_id == ^card_id, order_by: [desc: r.id])
  end

  @doc "The run's executions in insertion order — the per-attempt history W8 renders."
  def list_executions(%Run{id: run_id}) do
    Repo.all(from e in NodeExecution, where: e.run_id == ^run_id, order_by: [asc: e.id])
  end

  @doc "The run's single queued or claimed job, or nil."
  def active_job(%Run{id: run_id}) do
    # `run_id == ^run_id` already excludes talk jobs (always run_id: nil), but the kind clause
    # is explicit per ADR 0009 so the filter survives a future refactor of this query.
    Repo.one(
      from j in NodeJob,
        where: j.run_id == ^run_id and j.state in ^NodeJob.active_states() and j.kind in ^NodeJob.flow_kinds()
    )
  end

  @doc "Subscribes the calling process to `board_id`'s runs topic (`board:<id>:runs`)."
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  @doc """
  Coarse change signal for the read side (RLY-137): subscribers refetch the
  card's runs/summary rather than patching state from the fine-grained
  engine events also carried on this topic.
  """
  def broadcast_run_changed(board_id, card_id), do: broadcast_runs(board_id, {:run_changed, card_id})

  @doc "The card's runs newest-first, node executions preloaded chronologically."
  def list_runs_for_card(%Card{id: card_id}) do
    node_executions = from ne in NodeExecution, order_by: [asc: ne.id]

    Repo.all(
      from r in Run,
        where: r.card_id == ^card_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [node_executions: ^node_executions]
    )
  end

  @doc "The card's most recent run, or nil."
  def latest_run(%Card{} = card), do: card |> list_runs_for_card() |> List.first()

  @doc """
  The board's card faces in one pass: %{card_id => summary} for every card
  whose latest run exists. Three queries (latest run per card, node-execution
  aggregates, flows for happy paths) — no per-card N+1. `duration_s` sums the
  `finished_at - started_at` gap of each execution (the schema stores no
  duration column); an in-flight execution (`finished_at: nil`) contributes
  nothing to the sum. `flow_version` is nil — the run points at the live flow
  row and carries no version column yet (RLY-152).
  """
  # The zero totals a run with no node executions contributes — the fallback for a run id absent
  # from node_totals/1. Named once so both summary readers share it (AGENTS.md "a fact defined once").
  @empty_totals %{duration_s: nil, cost: nil, nodes: 0, attempts: 0, last_node: nil}

  def run_summaries_for_board(%Board{id: board_id}) do
    latest =
      Repo.all(
        from r in Run,
          join: c in Card,
          on: c.id == r.card_id,
          where: c.board_id == ^board_id,
          distinct: r.card_id,
          order_by: [asc: r.card_id, desc: r.inserted_at, desc: r.id]
      )

    totals = node_totals(Enum.map(latest, & &1.id))

    paths =
      from(f in Flow, where: f.board_id == ^board_id)
      |> Repo.all()
      |> Map.new(&{&1.key, happy_path(&1)})

    Map.new(latest, fn run ->
      path = Map.get(paths, run.flow_key, [])
      tot = Map.get(totals, run.id, @empty_totals)
      {run.card_id, build_summary(run, path, tot)}
    end)
  end

  @doc """
  The card-face summary for a single card's latest run, or `nil` when the card has
  no run — the one-card variant of `run_summaries_for_board/1` (RLY-204). BoardLive
  calls this to refetch only the card a run event names, instead of re-aggregating
  every run on the board. Both functions build each run's summary through the shared
  private `build_summary/3`, so the summary map shape is defined exactly once.
  """
  def run_summary_for_card(%Card{} = card) do
    case latest_run(card) do
      nil ->
        nil

      run ->
        totals = Map.get(node_totals([run.id]), run.id, @empty_totals)
        build_summary(run, happy_path_for(card, run), totals)
    end
  end

  # ---- Flow metrics (RLY-209) ----

  @metric_windows ~w(7d 30d all)

  @doc "The closed set of metrics windows. Defined once; LiveView, controller and CLI read it."
  def metric_windows, do: @metric_windows

  @doc "Default metrics window."
  def default_window, do: "30d"

  @doc "Completed-run count below which per-node percentiles aren't worth trusting (empty state)."
  def min_runs_for_percentiles, do: 10

  @doc """
  Per-node rollup for `flow` over `opts[:window]` (one of `metric_windows/0`, default
  `default_window/0`). Returns one map per node key that has executions in the window, in the
  flow's node order. `runs` counts node executions, not cards. See moduledoc semantics.
  """
  def node_metrics_for_flow(%Flow{} = flow, opts \\ []) do
    since = opts |> Keyword.get(:window, default_window()) |> normalize_window() |> window_since()

    numeric = node_numeric_rows(flow, since)
    verdicts = node_verdict_counts(flow, since)

    flow.nodes
    |> Enum.map(& &1.key)
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(numeric, &1))
    |> Enum.map(fn key ->
      Map.put(numeric[key], :verdict_split, verdict_split(Map.get(verdicts, key, %{})))
    end)
  end

  @doc "Stat-band summary for `flow` over `opts[:window]`."
  def flow_metrics_summary(%Flow{} = flow, opts \\ []) do
    since = opts |> Keyword.get(:window, default_window()) |> normalize_window() |> window_since()

    run_stats =
      from(r in Run,
        join: c in Card,
        on: c.id == r.card_id,
        where: c.board_id == ^flow.board_id and r.flow_key == ^flow.key,
        select: %{
          total_runs: count(r.id),
          completed: filter(count(r.id), r.status == :done),
          median:
            fragment(
              "percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)))",
              r.finished_at,
              r.started_at
            )
        }
      )
      |> filter_runs_since(since)
      |> Repo.one()

    total = run_stats.total_runs

    %{
      total_runs: total,
      completed: run_stats.completed,
      completed_pct: if(total > 0, do: round(run_stats.completed * 100 / total), else: 0),
      total_spend: flow_total_spend(flow, since),
      median_end_to_end: round_secs(run_stats.median)
    }
  end

  # ---- Board-health audit (RE249) ----

  @doc """
  The flow's runs within `opts[:window]` (one of `metric_windows/0`, default `default_window/0`)
  with `:node_executions` preloaded, ordered `started_at` ASC then `id` ASC, executions ordered
  by `id`. `Relay.Runs.Audit` reasons about "the next execution", so a stable order is part of
  the contract, not a convenience.
  """
  def recent_runs_for_flow(%Flow{} = flow, opts \\ []) do
    since = opts |> Keyword.get(:window, default_window()) |> normalize_window() |> window_since()
    executions = from(ne in NodeExecution, order_by: [asc: ne.id])

    from(r in Run,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^flow.board_id and r.flow_key == ^flow.key,
      order_by: [asc: r.started_at, asc: r.id],
      preload: [node_executions: ^executions]
    )
    |> filter_runs_since(since)
    |> Repo.all()
  end

  @doc """
  Board-health findings for `flow` over `opts[:window]` — `Relay.Runs.Audit.findings/2` over
  `recent_runs_for_flow/2`. The web layer's only door to the audit, so it never reaches past the
  Runs boundary.

  Returns `%{runs: how_many_were_examined, findings: [...]}`: the count is what the report's
  `(30d, 14 runs)` header states, and producing it here avoids a second query or a
  boundary-crossing load in the controller.
  """
  def audit(%Flow{} = flow, opts \\ []) do
    runs = recent_runs_for_flow(flow, opts)
    %{runs: length(runs), findings: Audit.findings(flow, runs)}
  end

  # One grouped pass over node_executions for the numeric columns. percentile_cont ignores NULLs,
  # so a node with unset cost / open timestamps yields nil there without a FILTER clause.
  defp node_numeric_rows(%Flow{} = flow, since) do
    from(ne in NodeExecution,
      join: r in Run,
      on: r.id == ne.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^flow.board_id and r.flow_key == ^flow.key,
      group_by: ne.node_key,
      select: %{
        node_key: ne.node_key,
        runs: count(ne.id),
        duration_p50:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)))",
            ne.finished_at,
            ne.started_at
          ),
        duration_p95:
          fragment(
            "percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)))",
            ne.finished_at,
            ne.started_at
          ),
        cost_p50: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", ne.cost),
        cost_p95: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", ne.cost),
        attempts_mean: fragment("COUNT(*)::float / NULLIF(COUNT(DISTINCT (?, ?)), 0)", ne.run_id, ne.visit),
        loop_laps: fragment("COUNT(DISTINCT (?, ?)) FILTER (WHERE ? > 1)", ne.run_id, ne.visit, ne.visit)
      }
    )
    |> filter_since(since)
    |> Repo.all()
    |> Map.new(fn row ->
      {row.node_key,
       %{
         node_key: row.node_key,
         runs: row.runs,
         duration_p50: round_secs(row.duration_p50),
         duration_p95: round_secs(row.duration_p95),
         cost_p50: to_decimal(row.cost_p50),
         cost_p95: to_decimal(row.cost_p95),
         attempts_mean: (row.attempts_mean || 0.0) * 1.0,
         loop_laps: row.loop_laps || 0
       }}
    end)
  end

  # Verdict counts as a separate grouped pass so the outcome set stays sourced from
  # NodeExecution.outcomes/0 rather than retyped as SQL literals.
  defp node_verdict_counts(%Flow{} = flow, since) do
    from(ne in NodeExecution,
      join: r in Run,
      on: r.id == ne.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^flow.board_id and r.flow_key == ^flow.key and not is_nil(ne.outcome),
      group_by: [ne.node_key, ne.outcome],
      select: {ne.node_key, ne.outcome, count(ne.id)}
    )
    |> filter_since(since)
    |> Repo.all()
    |> Enum.group_by(fn {key, _o, _c} -> key end)
    |> Map.new(fn {key, triples} ->
      {key, Map.new(triples, fn {_k, o, c} -> {o, c} end)}
    end)
  end

  defp verdict_split(counts) do
    Map.new(NodeExecution.outcomes(), fn outcome -> {outcome, Map.get(counts, outcome, 0)} end)
  end

  defp flow_total_spend(%Flow{} = flow, since) do
    from(ne in NodeExecution,
      join: r in Run,
      on: r.id == ne.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^flow.board_id and r.flow_key == ^flow.key,
      select: sum(ne.cost)
    )
    |> filter_since(since)
    |> Repo.one()
    |> to_decimal()
  end

  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: from([ne] in query, where: ne.started_at >= ^since)

  defp filter_runs_since(query, nil), do: query
  defp filter_runs_since(query, since), do: from([r] in query, where: r.started_at >= ^since)

  defp normalize_window(window) when window in @metric_windows, do: window
  defp normalize_window(_), do: default_window()

  defp window_since("all"), do: nil
  defp window_since("7d"), do: DateTime.add(now(), -7 * 86_400, :second)
  defp window_since("30d"), do: DateTime.add(now(), -30 * 86_400, :second)

  defp round_secs(nil), do: nil
  defp round_secs(seconds), do: round(seconds)

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: Decimal.round(d, 2)
  defp to_decimal(n) when is_integer(n), do: n |> Decimal.new() |> Decimal.round(2)
  defp to_decimal(n) when is_float(n), do: n |> Decimal.from_float() |> Decimal.round(2)

  # The one per-run summary map — built identically by run_summaries_for_board/1 (over the
  # whole board) and run_summary_for_card/1 (one card), so the shape lives in exactly one
  # place. `path` is the flow's happy path (drives node_index/node_count); `totals` is this
  # run's node-execution aggregate, or @empty_totals when it has no executions yet.
  defp build_summary(%Run{} = run, path, totals) do
    index = run.current_node && Enum.find_index(path, &(&1 == run.current_node))

    %{
      run_id: run.id,
      card_id: run.card_id,
      status: run.status,
      breaker_tripped?: breaker_tripped?(run),
      flow_key: run.flow_key,
      flow_version: nil,
      current_node: run.current_node,
      last_node: run.current_node || totals.last_node,
      node_index: index && index + 1,
      node_count: if(path == [], do: nil, else: length(path)),
      started_at: run.started_at,
      finished_at: run.finished_at,
      duration_s: totals.duration_s,
      cost: totals.cost,
      nodes: totals.nodes,
      attempts: totals.attempts
    }
  end

  # The single-flow analog of run_summaries_for_board/1's `paths` map: the happy path of the
  # flow this run points at (matched by key within the card's board, exactly as the board
  # function matches), or [] when that flow row is gone.
  defp happy_path_for(%Card{board_id: board_id}, %Run{flow_key: flow_key}) do
    case Relay.Flows.get_flow(%Board{id: board_id}, flow_key) do
      nil -> []
      flow -> happy_path(flow)
    end
  end

  @doc """
  Whether a run died because the circuit breaker actually tripped — the ONE
  breaker signal (RLY-207, moved from `RunComponents.circuit_tripped?/1`).

  `runs.failure_detail` carries the engine's reason verbatim and the
  `circuit_breaker:` token has exactly one producer (`Engine.decide/4`), so it is
  the honest discriminator. Matched as a substring, not a prefix, so bringing the
  breaker reason in line with the human-first house style can't silently un-trip it.

  RLY-194 will swap the internals here for a structured failure reason without
  touching callers.
  """
  def breaker_tripped?(%{status: :failed, failure_detail: detail}) when is_binary(detail),
    do: String.contains?(detail, "circuit_breaker:")

  def breaker_tripped?(_run), do: false

  @doc """
  The run-visibility read model for one run: `%Relay.Runs.RunDetail{}` derived
  purely from `run` (with `node_executions` preloaded) plus its `flow` (or nil).
  The web layer renders this instead of re-folding raw executions (RLY-207).
  """
  def run_detail(run, flow), do: Relay.Runs.RunDetail.build(run, flow)

  # A live run whose node-job is stuck (queued/unclaimed, or held by a silent executor) this long
  # has stopped moving. It never applies to a job a live executor is holding: working_run_ids/2
  # excludes those first, so a 40-minute plan-implementer node stays neutral no matter how far
  # past this threshold it runs (see run_stalled?/3, and RE255 for why that used to be false).
  @run_stale_after_s 300

  @doc """
  The run's last forward progress: the newest `node_executions.inserted_at`, falling back to the
  run's `inserted_at`. Forward progress only — `node_jobs.updated_at` is bumped by the very
  revoke/requeue loop that was the RLY-191 failure, so a run wedged in that loop (which makes no
  new executions) keeps this clock running, which is the point.
  """
  @spec last_progress_at(Run.t()) :: DateTime.t()
  def last_progress_at(%Run{id: run_id, inserted_at: inserted_at}) do
    Repo.one(from ne in NodeExecution, where: ne.run_id == ^run_id, select: max(ne.inserted_at)) || inserted_at
  end

  @doc "Bulk `last_progress_at/1` for a board: `%{run_id => DateTime.t()}`, one grouped query (no N+1). Runs with no executions are absent (the caller falls back to run start)."
  @spec last_progress_by_run(Board.t()) :: %{term() => DateTime.t()}
  def last_progress_by_run(%Board{} = board) do
    from(ne in NodeExecution,
      join: r in Run,
      on: r.id == ne.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^board.id,
      group_by: ne.run_id,
      select: {ne.run_id, max(ne.inserted_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Run ids whose current node-job is held by a live claim (`NodeJob.claimed_states/0`) on a
  non-stale executor at `now`. The complement — queued, unclaimed, or held by a silent executor —
  is what BoardLive treats as a candidate for the stalled run-face treatment. Reuses
  `executor_stale?/2`, so "working" can never disagree with what the reclaim sweep would act on.

  A claim IS the start signal: `bin/relay` claims a job and spawns its worker thread in the same
  loop iteration, so there is no meaningful claimed-but-not-working window (RE255). There is
  deliberately no time ceiling here — a hung-but-claimed agent is `Cards.health/1`'s signal, and
  a job on an executor that has gone silent is already excluded by `executor_stale?/2`.
  """
  @spec working_run_ids(Board.t(), DateTime.t()) :: MapSet.t()
  def working_run_ids(%Board{} = board, %DateTime{} = now) do
    live_names =
      board.id
      |> list_board_executors()
      |> Enum.reject(&executor_stale?(&1, now))
      |> MapSet.new(& &1.name)

    from(j in NodeJob,
      join: r in Run,
      on: r.id == j.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^board.id and j.state in ^NodeJob.claimed_states(),
      # Explicit: a talk job carries no run_id (excluded by the inner join already), and this
      # function's result is `run_id => executor_name`, which is meaningless for a talk turn.
      where: j.kind in ^NodeJob.flow_kinds(),
      select: {j.run_id, j.executor_name}
    )
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn {run_id, name}, acc ->
      if MapSet.member?(live_names, name), do: MapSet.put(acc, run_id), else: acc
    end)
  end

  @doc "Whether a run face should show the amber stalled treatment: not currently working AND its last progress is older than `@run_stale_after_s`. The single home of the 5-minute policy."
  @spec run_stalled?(DateTime.t() | nil, boolean(), DateTime.t()) :: boolean()
  def run_stalled?(nil, _working?, _now), do: false
  def run_stalled?(_progress_at, true, _now), do: false
  def run_stalled?(progress_at, false, now), do: DateTime.diff(now, progress_at, :second) > @run_stale_after_s

  @doc """
  The node the run was last at: `current_node` while the run is live, else the
  `node_key` of its most recent `NodeExecution`.

  `close_run!/3` nils `current_node` on every terminal close, so a closed run's
  board tile would otherwise name no node at all (RLY-159). Ordering is
  `started_at` desc with `id` desc as tiebreak — `started_at` is second-precision,
  so two executions in the same second are separated by insertion order.
  """
  def last_node(%{current_node: node_key}, _node_executions) when is_binary(node_key), do: node_key

  def last_node(_run, []), do: nil

  def last_node(_run, node_executions) do
    node_executions
    |> Enum.max_by(&{DateTime.to_unix(&1.started_at), &1.id})
    |> Map.fetch!(:node_key)
  end

  defp node_totals([]), do: %{}

  defp node_totals(run_ids) do
    from(ne in NodeExecution,
      where: ne.run_id in ^run_ids,
      group_by: ne.run_id,
      select:
        {ne.run_id,
         %{
           duration_s: sum(fragment("EXTRACT(EPOCH FROM (? - ?))::integer", ne.finished_at, ne.started_at)),
           cost: sum(ne.cost),
           nodes: count(ne.node_key, :distinct),
           attempts: count(ne.id),
           last_node: fragment("(array_agg(? ORDER BY ? DESC, ? DESC))[1]", ne.node_key, ne.started_at, ne.id)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Happy-path linearization of a flow: node keys from the start edge following
  :succeeded edges until the done sentinel (cycle-safe — stops on revisit).
  """
  def happy_path(%Flow{edges: edges}) do
    next = Map.new(edges || [], fn edge -> {{edge.from, edge.on}, edge.to} end)
    walk(next[{"start", nil}], next, [])
  end

  defp walk(node, _next, acc) when node in [nil, "done"], do: Enum.reverse(acc)

  defp walk(node, next, acc) do
    if node in acc do
      Enum.reverse(acc)
    else
      walk(next[{node, :succeeded}], next, [node | acc])
    end
  end

  @doc """
  The enabled flow that will pick this card up, or nil. Queued (spec decision):
  an enabled flow pulls from the card's stage, the card is AI-ready (:ready +
  baton with AI), and no active run exists. Pure — no scheduler/NodeJob read.
  """
  def queued_flow(%Card{} = card, active_owner, flows, summary) do
    active_run? = summary != nil and summary.status in Run.active_statuses()

    if Policy.pullable?(%{status: card.status, active_owner: active_owner}) and not active_run? do
      Enum.find(flows, &(&1.enabled and &1.pulls_from_stage_id == card.stage_id))
    end
  end

  @doc """
  What the board card face shows: {:run, summary} for an active run, or for a
  terminal run while the card still sits in one of that run's flow's trigger
  stages (pulls-from / works-in / lands-on — the spec's "hasn't moved on" rule
  made precise, so a done run's totals survive landing on lands-on);
  {:queued, flow} when queued; nil → legacy strip logic.
  """
  def face_summary(%Card{} = card, active_owner, flows, summaries) do
    summary = Map.get(summaries, card.id)

    cond do
      summary != nil and summary.status in Run.active_statuses() ->
        {:run, summary}

      summary != nil and terminal_still_relevant?(card, summary, flows) ->
        {:run, summary}

      true ->
        case queued_flow(card, active_owner, flows, summary) do
          nil -> nil
          flow -> {:queued, flow}
        end
    end
  end

  defp terminal_still_relevant?(card, summary, flows) do
    case Enum.find(flows, &(&1.key == summary.flow_key)) do
      nil ->
        false

      flow ->
        card.stage_id in [
          flow.pulls_from_stage_id,
          flow.works_in_stage_id,
          flow.lands_on_stage_id
        ]
    end
  end

  ## Lifecycle

  @doc """
  Starts a run of `flow` for `card` (same board enforced by the pattern
  match). Guards: the flow must be enabled, its graph must use only
  supported node types (`:human`/`:parallel` → `{:error,
  :unsupported_node_type}`; execution of both is card 09), its start edge
  must target a real node, and the card must have no active run (the
  partial unique index backs this against races). Creates the run + first
  execution + queued job in one transaction, moves the card to the flow's
  works-in stage as `:agent` (the claim rule assigns Relay AI on an
  unowned card), then explicitly sets the card `:working` via
  `set_status/3` — ADR 0003's move-time snap only overrides an INVALID
  status, and `:ready` is already valid on a work-type stage, so the
  hand-over to the AI needs its own explicit status set. Broadcasts,
  starts a `RunServer`, and dispatches. A card already sitting in the
  works-in stage is NOT re-moved (rejection re-entry: a gratuitous
  append-move would clear the CHANGES REQUESTED banner via
  `move_card`'s rejection-clearing rule) but is still set `:working`.
  `opts[:context]` is a STRING-keyed map (e.g.
  `%{"changes_requested" => note}`) merged into every job payload's vars.
  """
  def start_run(%Card{board_id: board_id} = card, %Flow{board_id: board_id} = flow, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    start_target = Enum.find(flow.edges, &(&1.from == "start")).to

    cond do
      not flow.enabled -> {:error, :flow_disabled}
      Enum.any?(flow.nodes, &(&1.type not in Flow.Node.runnable_types())) -> {:error, :unsupported_node_type}
      start_target == "done" -> {:error, :empty_flow}
      true -> do_start_run(card, flow, start_target, context)
    end
  end

  defp do_start_run(card, flow, start_target, context) do
    case maybe_seed_sub_tasks(card, flow) do
      :ok -> start_seeded_run(card, flow, start_target, context)
      {:error, :no_plan_tasks} -> block_on_unusable_plan(card, flow)
    end
  end

  # No run is created, and the card blocks on a human: a `:needs_input` card is skipped by
  # the scheduler by rule, so this reports the defect once instead of the scheduler re-pulling
  # a card it can never work.
  defp block_on_unusable_plan(card, flow) do
    {:ok, _card} =
      Cards.request_input(
        card,
        "The #{flow.key} flow could not start: this card's plan produced no tasks. " <>
          "Its `foreach` node iterates the plan's `## Task N: <name>` headings (two to four " <>
          "hashes) and found none, so there is nothing to implement. Fix the plan's task " <>
          "headings and move the card back to re-run.",
        :agent
      )

    {:error, :no_plan_tasks}
  end

  defp start_seeded_run(card, flow, start_target, context) do
    result =
      Repo.transaction(fn ->
        card = move_into_work_lane(card, flow)
        run = insert_run(card, flow, start_target, context)
        sub_task_id = if start_target == foreach_node_key(flow), do: next_sub_task_id(run)
        execution = insert_execution!(run, start_target, 1, 1, sub_task_id)
        job = insert_job!(run, execution, build_payload(run, flow, start_target, sub_task_id: sub_task_id))
        {card, run, execution, job}
      end)

    case result do
      {:ok, {card, run, execution, job}} ->
        broadcast_runs(card.board_id, {:run_started, run})
        broadcast_runs(card.board_id, {:node_started, run, execution})
        {:ok, _pid} = ensure_server(run, {:dispatch, job.id})
        {:ok, run}

      {:error, %Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :card_id), do: {:error, :active_run_exists}, else: {:error, :invalid}
    end
  end

  # RLY-233 Part 1: move the card into the flow's work lane and set it :working BEFORE the run
  # row is inserted, inside start_seeded_run's single transaction. This guarantees no committed
  # state ever has an active run while the card still sits at its (often :done-type) pull stage,
  # so "active run + terminal stage" becomes an unambiguous leak signal (Part 2). Moving first
  # also sidesteps stranded_run/2 — there is no active run at move time.
  #
  # A card already in the work lane (rejection re-entry) is NOT re-moved: a gratuitous
  # append-move would clear the CHANGES REQUESTED banner via move_card's rejection-clearing rule.
  # The move's snap only overrides an INVALID status (ADR 0003); :ready is already valid on a
  # work stage, so the AI taking over needs an explicit :working — status changes only ever
  # happen through set_status/3.
  defp move_into_work_lane(card, flow) do
    moved =
      if card.stage_id == flow.works_in_stage_id do
        card
      else
        works_in = Repo.get!(Stage, flow.works_in_stage_id)
        {:ok, moved} = Cards.move_card(card, works_in, @append_index, :agent)
        moved
      end

    {:ok, working} = Cards.set_status(moved, %{status: :working}, :agent)
    working
  end

  # A `foreach` flow iterates the card's sub_tasks, so the server materializes them
  # from the card's plan at RUN START (never on re-entry — that would wipe
  # done-state). A card whose sub_tasks were already written (by the Plan stage, or
  # by a human) is left alone: the authored list wins over the parsed one.
  #
  # Returns `{:error, :no_plan_tasks}` when the flow iterates the plan but no task list can
  # be produced. That case MUST NOT start the run (RLY-165): with zero sub_tasks the first
  # foreach guard reads `remaining == 0` as `:foreach_exhausted` and routes straight past
  # every implement lap to `precommit` — trivially green on an empty diff — then reviews,
  # smoke and `merge`. An unreadable plan would merge an empty branch as though the work
  # were done. `:foreach_exhausted` must mean "I finished the work", never "I found none".
  defp maybe_seed_sub_tasks(card, flow) do
    cond do
      not Enum.any?(flow.nodes, &(not is_nil(&1.foreach))) ->
        :ok

      Repo.exists?(from st in SubTask, where: st.card_id == ^card.id) ->
        :ok

      true ->
        case PlanTasks.parse(card.plan) do
          [_ | _] = tasks ->
            {:ok, _card} = Cards.set_sub_tasks(card, tasks)
            :ok

          [] ->
            {:error, :no_plan_tasks}
        end
    end
  end

  defp insert_run(card, flow, start_target, context) do
    %Run{
      card_id: card.id,
      flow_id: flow.id,
      flow_key: flow.key,
      status: :running,
      current_node: start_target,
      context: context,
      started_at: now()
    }
    |> Run.changeset()
    |> Repo.insert()
    |> case do
      {:ok, run} -> run
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc """
  Reports a node outcome for `job` — `%{outcome:, detail:, git_sha:,
  session_id:, cost:}`, outcome required from the closed set. Finalizes
  the execution + job and hands the outcome to the run's `RunServer`
  (serialized per run). Jobs not in queued/claimed are rejected
  with `{:error, :job_not_active}` — a revoked job's late report is
  dropped.
  """
  def report_outcome(job, attrs)

  def report_outcome(%NodeJob{} = job, %{outcome: outcome} = attrs) do
    if outcome in NodeExecution.outcomes() do
      job = Repo.get!(NodeJob, job.id)
      run = Repo.get!(Run, job.run_id)

      if job.state in NodeJob.active_states() and run.status == :running do
        {:ok, pid} = ensure_server(run, :attach)
        GenServer.call(pid, {:report_outcome, job.id, attrs}, :infinity)
      else
        {:error, :job_not_active}
      end
    else
      {:error, :invalid_outcome}
    end
  end

  def report_outcome(%NodeJob{}, _attrs), do: {:error, :invalid_outcome}

  @doc "queued → claimed (04's claim endpoint becomes a thin wrapper). Race-proof via a guarded UPDATE."
  def claim_job(%NodeJob{} = job, executor_name) when is_binary(executor_name) do
    transition_job(job, [:queued], state: :claimed, executor_name: executor_name, claimed_at: now())
  end

  defp transition_job(job, from_states, sets) do
    query = from j in NodeJob, where: j.id == ^job.id and j.state in ^from_states, select: j

    case Repo.update_all(query, set: sets) do
      {1, [updated]} -> {:ok, updated}
      {0, _none} -> {:error, :job_not_active}
    end
  end

  @doc """
  Cancels an active run: stops its server, revokes any in-flight job,
  marks the run `:cancelled`, and logs an `:action` entry (`log_text`,
  default `"run cancelled"`) to the card's timeline. The card itself is
  left where it sits.
  """
  def cancel_run(%Run{} = run, log_text \\ "run cancelled") do
    stop_server(run)
    run = Repo.get!(Run, run.id)
    revoke_active_jobs(run)

    case Transitions.transition(run, Run.active_statuses(), :cancelled,
           set: [parked_reason: nil, current_node: nil, failure_detail: nil, finished_at: now()]
         ) do
      {:ok, cancelled} ->
        card = Repo.get!(Card, cancelled.card_id)
        {:ok, _entry} = Activity.log(card, %{type: :action, actor: :agent, text: log_text})
        broadcast_runs(card.board_id, {:run_finished, cancelled})
        {:ok, cancelled}

      {:error, :not_in_expected_state} ->
        {:error, :not_active}
    end
  end

  @doc """
  Closes every leaked run — a run still `active` (`Run.active_statuses/0`) whose card already
  sits in a terminal-type stage (`Stage.terminal_types/0`) — and returns the count closed.
  Joins run → card → stage across all boards and routes each through `cancel_run/2`, which stops
  its server, revokes its in-flight job (freeing a `shared_clean` slot), closes it `:cancelled`
  and drops it from `active_runs`/capacity (freeing an `exclusive` slot), logs, and broadcasts.
  Idempotent — a second call finds none (`cancel_run/2` returns `{:error, :not_active}` on a
  now-terminal run). Invoked by the `ExecutorReaper` tick and usable directly as a catch-up.
  """
  def close_orphaned_runs do
    from(r in Run,
      join: c in Card,
      on: c.id == r.card_id,
      join: s in Stage,
      on: s.id == c.stage_id,
      where: r.status in ^Run.active_statuses() and s.type in ^Stage.terminal_types()
    )
    |> Repo.all()
    |> Enum.reduce(0, fn run, closed ->
      case cancel_run(run, "run closed — card already completed") do
        {:ok, _cancelled} -> closed + 1
        {:error, :not_active} -> closed
      end
    end)
  end

  @doc """
  True if `run` is a leak — still `active` (`Run.active_statuses/0`) while its card already sits in
  a terminal-type stage (`Stage.terminal_types/0`) — decided in ONE `run → card → stage` query, so
  the verdict is a single consistent snapshot (the same predicate `close_orphaned_runs/0` sweeps
  with).

  Atomic dispatch (`start_seeded_run/4` moves the card into the work lane *before* inserting the
  run, in one transaction) guarantees no committed state ever pairs an active run with a card still
  at its (often `:done`-type) pull stage, so a freshly dispatched run is never a leak — only a
  genuinely stranded one is. The listener's terminal-close rule uses this instead of reading the
  card stage and the active run in separate queries, which could straddle a concurrent
  `Spec:Done → Plan` dispatch and cancel the fresh plan run (RLY-233 / RE239).
  """
  def leaked?(%Run{id: id}) do
    Repo.exists?(
      from(r in Run,
        join: c in Card,
        on: c.id == r.card_id,
        join: s in Stage,
        on: s.id == c.stage_id,
        where: r.id == ^id and r.status in ^Run.active_statuses() and s.type in ^Stage.terminal_types()
      )
    )
  end

  ## Executors (ADR 0006 card 04)

  # The oldest `bin/relay` EXECUTOR_VERSION this server will hand work to (RLY-184). One
  # module owns the number; the controller and the runners view read it through
  # min_executor_version/0 rather than re-deriving it. Raise it only when running the old
  # executor is genuinely worse than a stopped one — every executor below it is refused at
  # claim until a human restarts it.
  # RLY-223 raised this to 19: the Code flow's `branch` node now writes the plan to the
  # executor-exported $RELAY_PLAN, so a pre-19 executor (which never exports it) would write to
  # an empty path and fail every Code run — genuinely worse than a stopped one (AGENTS.md).
  # (RLY-224 landed EXECUTOR_VERSION 18 on main first, with git-fetch retry but no $RELAY_PLAN
  # support, so 18 alone is NOT sufficient here — the floor must be the version that actually
  # carries RELAY_PLAN, which is 19 once both changes are combined.)
  # RLY-231 raised this to 21: the executor moved from a fixed reused slot pool (`exec-work-N`,
  # bound through an in-memory map) to one fresh worktree per card. A pre-21 executor still runs
  # the slot pool and reads the heartbeat `release_runs` reply as bare ids (it is now
  # {run_id, status} maps), so against the new server it would mis-bind worktrees and never
  # release them — worse than a stopped one.
  @min_executor_version 21

  @doc "The minimum `bin/relay` EXECUTOR_VERSION this server will claim jobs to."
  def min_executor_version, do: @min_executor_version

  # RE268 — a SECOND, higher floor that applies only to `kind: :talk` jobs. A talk job is
  # unpinned on a card's first turn and deliberately bypasses the capacity filter, so without
  # this ANY executor at or above @min_executor_version could take it — including every
  # pre-Talk executor, which reads `job["isolation"]`, raises `KeyError`, rejects the job and
  # then 404s on the flow-only outcome route. The turn is left `:claimed` forever (the orphan
  # reaper deliberately skips talk jobs) and `Talk.post_message/3` refuses every later turn with
  # `:turn_in_flight` — one stale executor wedges Talk for the whole board.
  #
  # Kept separate from @min_executor_version on purpose: raising THAT would also stop old
  # executors doing the flow work they still handle correctly.
  @min_talk_executor_version 39

  @doc "The minimum `bin/relay` EXECUTOR_VERSION that may claim a `kind: :talk` job (ADR 0009)."
  def min_talk_executor_version, do: @min_talk_executor_version

  @doc """
  Whether this executor is new enough to RUN a talk turn, not merely new enough to claim
  flow work. See `min_talk_executor_version/0`.
  """
  def talk_capable?(%Executor{version: version}) when is_integer(version), do: version >= @min_talk_executor_version

  def talk_capable?(%Executor{}), do: false

  # RE304: the version an executor can actually FETCH is the `EXECUTOR_VERSION` of the
  # `bin/relay` this app SERVES at /api/scaffold — truthful by construction, which is exactly
  # what the retired `.relay/published.json` marker existed to paper over. Deliberately NOT
  # min_executor_version/0 (a floor, not a target). Read at RUNTIME, from `priv/scaffold/`,
  # because a Mix release ships `priv/` but ships neither `bin/` nor `.claude/`.

  @doc """
  The newest `bin/relay` EXECUTOR_VERSION an executor can download, or `nil`.

  `nil` when the scaffold has not been built, which reads on the wire as "never auto-update" —
  the correct answer when there is nothing to fetch.
  """
  @spec latest_executor_version() :: integer() | nil
  def latest_executor_version, do: Relay.Scaffold.executor_version()

  @doc """
  Whether this executor is running code older than the server requires.

  `nil` is outdated by construction: an executor that reports no version predates RLY-184,
  which is definitionally behind. That flags every currently-running stale process the moment
  this ships — the desired outcome, not an edge case.
  """
  def executor_outdated?(%Executor{version: version}) when is_integer(version), do: version < @min_executor_version

  def executor_outdated?(%Executor{}), do: true

  @doc """
  Upserts the durable executor row keyed `{board_id, name}`, refreshing host,
  interval, capacity, and `last_heartbeat`. Called by the claim endpoint (claim
  doubles as a liveness touch) and by the extended heartbeat's capacity branch.
  `attrs` is a STRING-keyed map (`"name"`, `"host"`, `"interval"`, `"capacity"`,
  and optionally `"capabilities"`).

  `capabilities` rides send-on-change (RLY-182), so most beats omit it. The replace
  list is therefore built per-call: replacing with the insert's values would null out
  a good row on every beat that didn't carry the key, and preflight would then report
  a healthy executor as missing every agent.
  """
  def upsert_executor(%Board{id: board_id}, attrs) do
    params = %{
      board_id: board_id,
      name: to_string(attrs["name"]),
      host: to_string(attrs["host"] || ""),
      interval: normalize_interval(attrs["interval"]),
      capacity: normalize_capacity(attrs["capacity"]),
      version: normalize_version(attrs["version"]),
      last_heartbeat: now()
    }

    {params, replace} =
      case normalize_capabilities(attrs["capabilities"]) do
        nil ->
          {params, [:host, :interval, :capacity, :version, :last_heartbeat, :updated_at]}

        capabilities ->
          {Map.put(params, :capabilities, capabilities),
           [:host, :interval, :capacity, :capabilities, :version, :last_heartbeat, :updated_at]}
      end

    %Executor{}
    |> Executor.changeset(params)
    |> Repo.insert(
      on_conflict: {:replace, replace},
      conflict_target: [:board_id, :name],
      returning: true
    )
  end

  defp normalize_interval(i) when is_integer(i) and i > 0, do: i
  defp normalize_interval(_i), do: 30

  # Non-integer / negative → nil, i.e. "outdated". Untrusted input must degrade, not raise.
  defp normalize_version(v) when is_integer(v) and v >= 0, do: v
  defp normalize_version(_v), do: nil

  # RLY-201: one normalizer. The row and the ETS store must agree on what a malformed
  # payload means, so both go through Relay.Runs.Capacity.normalize/1. Ecto stringifies
  # the atom keys on save, so the row reads back as
  # %{"shared_clean" => n, "exclusive" => n}.
  defp normalize_capacity(cap), do: Capacity.normalize(cap)

  # nil = "this beat did not report an inventory" — the caller must then leave the stored
  # value alone. A malformed payload is treated the same way rather than stored as junk.
  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    %{
      "agents" => normalize_names(capabilities["agents"]),
      "skills" => normalize_names(capabilities["skills"])
    }
  end

  defp normalize_capabilities(_capabilities), do: nil

  defp normalize_names(names) when is_list(names) do
    names |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()
  end

  defp normalize_names(_names), do: []

  @doc """
  Atomically claims the next eligible `queued` job for `executor`, scoped to
  the executor's board (a board-A key must never see board-B's jobs — the
  claim payload carries the run's `ref`/`vars`, so this is an authz boundary,
  not just filtering): the oldest job whose `payload["isolation"]` is a class
  with advertised free capacity `> 0` and that is unpinned (`executor_name`
  nil) or already pinned to this executor. `SELECT … FOR UPDATE SKIP LOCKED`
  inside a transaction so two executors never grab the same job. Returns
  `{:ok, job}` or `{:ok, nil}` when nothing matches.
  """
  def claim_next_job(%Executor{board_id: board_id, name: name, capacity: capacity} = executor) do
    allowed = for {class, n} <- capacity, is_integer(n) and n > 0, do: class
    # RE268 — a talk job is only visible to an executor that can actually run one
    # (`talk_capable?/1`); an older executor still sees the flow kinds it handles correctly.
    kinds = if talk_capable?(executor), do: NodeJob.kinds(), else: NodeJob.flow_kinds()
    # Never short-circuit on empty capacity: a job pinned to this executor (an
    # exclusive run it already holds — ADR 0006 §5) is claimable regardless of
    # advertised free capacity, since the executor is already holding that slot.
    Repo.transaction(fn -> do_claim_next_job(board_id, name, allowed, kinds) end)
  end

  defp do_claim_next_job(board_id, name, allowed, kinds) do
    query =
      from j in NodeJob,
        join: c in Card,
        on: c.id == j.card_id,
        where: c.board_id == ^board_id,
        where: j.state == :queued,
        where: j.kind in ^kinds,
        # Unpinned FLOW jobs need advertised free capacity in their class; a job already
        # pinned to this executor bypasses the capacity filter. An unpinned TALK job also
        # bypasses it (ADR 0009 §3): a turn runs in the card's own worktree and advertises no
        # isolation class, and the FIRST turn on a card is what CREATES the executor pin, so
        # refusing it for want of an advertised slot would mean a card nobody has talked to
        # can never be talked to on a busy executor. The exemption is the SERVER's: `assign_talk`
        # in `bin/relay` still refuses a turn once the executor is at `max_worktrees`, and the
        # person gets an immediate failed turn rather than a queue-and-wait (a known gap —
        # runner.md "Talk"). This clause only ensures the job is offered at all.
        where:
          j.executor_name == ^name or
            (is_nil(j.executor_name) and
               (j.kind == ^NodeJob.talk_kind() or fragment("?->>'isolation'", j.payload) in ^allowed)),
        order_by: [asc: j.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"

    case Repo.one(query) do
      nil ->
        nil

      job ->
        {:ok, claimed} = claim_job(job, name)
        maybe_pin_run(claimed, name)
        claimed
    end
  end

  # On claiming an exclusive run's job, persist the holder on the run row so BOTH
  # readers — the claim layer (exclusive_holder/2) and the scheduler (active_runs/1) —
  # derive the same pin from ONE column (RLY-199). Idempotent: a re-claim by the same
  # holder rewrites the same name. shared_clean runs are never pinned. A talk payload never
  # matches `%{"isolation" => "exclusive"}`, so this is a no-op for talk — the TALK pin is
  # written by `Relay.Talk.finish_turn/3` onto the session row instead, one column, one
  # writer, per RLY-199's rule.
  defp maybe_pin_run(%NodeJob{run_id: run_id, payload: %{"isolation" => "exclusive"}}, name) do
    Repo.update_all(from(r in Run, where: r.id == ^run_id), set: [pinned_executor_name: name])
    :ok
  end

  defp maybe_pin_run(_job, _name), do: :ok

  @doc """
  Of the job ids an executor reports it is running, those the server no longer considers
  live (RLY-164) — i.e. anything not in NodeJob.active_states() on THIS board, plus ids that
  don't exist here at all.

  Board-scoped on purpose: an id belonging to another board is not live *here*, so it comes
  back as revoked-for-this-executor only if this board owns it. That prevents one board's
  executor being told to kill another board's work, and it means a stale or malicious id is
  harmless. Non-integer ids are ignored rather than raising — this is a heartbeat, and a
  malformed beat must never 500 a liveness path.
  """
  def revoked_among(%Board{id: board_id}, running_ids) when is_list(running_ids) do
    ids = for id <- running_ids, int = to_job_id(id), is_integer(int), do: int

    case ids do
      [] ->
        []

      ids ->
        # Only ids this board actually owns are candidates. An id we don't own is NOT
        # reported revoked: instructing an executor to kill work on the strength of an id
        # we can't see would cross the board boundary, and a stale/garbage id would become
        # a kill order. Jobs are never hard-deleted — they transition to :revoked/:done — so
        # "exists here and is no longer active" covers every real revoke.
        #
        # Joined on card_id (not through Run) so TALK jobs are included — this is what makes
        # the Stop button reach the executor: `Relay.Runs.revoke_talk_job/1` flips the job to
        # :revoked, and the executor learns to kill its `claude -p` from this same heartbeat
        # path a flow job's revoke already used.
        on_board =
          Repo.all(
            from j in NodeJob,
              join: c in Card,
              on: c.id == j.card_id,
              where: c.board_id == ^board_id and j.id in ^ids,
              select: {j.id, j.state}
          )

        for {id, state} <- on_board, state not in NodeJob.active_states(), do: id
    end
  end

  def revoked_among(_board, _running), do: []

  @doc """
  Of the job ids an executor reports it is running, stamp `agent_heartbeat_at = now` on the cards
  whose job is still active (`state in NodeJob.active_states()`) on THIS board (RLY-226). This is
  the exact positive complement of `revoked_among/2` — revoked = on-board but NOT active; refresh =
  on-board AND active — and it is the "a live executor is actively holding this card" signal wired
  into `Cards.health/1`, so a quiet-but-running agent no longer falsely ages to `:stale`.

  Requiring `active_states()` (not merely "reported running") is the conservative, self-consistent
  rule `revoked_among/2` uses: a job the server has already finalized or revoked can never be kept
  falsely alive.

  Board-scoped like `revoked_among/2` — an id belonging to another board is not refreshed here, so
  one board's beat can never keep another board's card alive. The single write is delegated to
  `Cards.touch_heartbeats/2`, keeping `agent_heartbeat_at` to exactly one write site (one
  `update_all`, deliberately no broadcast). Non-integer / unknown ids are ignored; `[]` → `{0, nil}`
  with no query — a heartbeat must never 500 on a malformed beat.
  """
  def refresh_running_card_liveness(%Board{id: board_id} = board, running_ids) when is_list(running_ids) do
    ids = for id <- running_ids, int = to_job_id(id), is_integer(int), do: int

    case ids do
      [] ->
        {0, nil}

      ids ->
        refs =
          from(j in NodeJob,
            join: r in Run,
            on: r.id == j.run_id,
            join: c in Card,
            on: c.id == r.card_id,
            # A talk turn is not the agent working the card (ADR 0009 §6: the baton does not
            # move), so it must never stamp agent_heartbeat_at — the inner join on Run already
            # excludes it (a talk job's run_id is nil), and this filter makes that exclusion
            # explicit rather than incidental.
            where: c.board_id == ^board_id and j.id in ^ids and j.state in ^NodeJob.active_states(),
            where: j.kind in ^NodeJob.flow_kinds(),
            select: c.ref_number
          )
          |> Repo.all()
          |> Enum.map(&Cards.ref(board, %Card{ref_number: &1}))

        Cards.touch_heartbeats(board, refs)
    end
  end

  def refresh_running_card_liveness(_board, _running), do: {0, nil}

  @doc """
  The subset of `bound_run_ids` whose run is TERMINAL (`status in Run.terminal_statuses()`) on
  THIS board — the run-scoped analogue of `revoked_among/2`, one level up. The executor reports
  the run-ids of exclusive slots it holds with no live job (`bound_runs`); this names the ones it
  may now release, because the run has ended server-side. Returned as `%{id, status}` maps so the
  executor's recovery teardown can choose remove (done/cancelled) vs retain (failed).

  Board-scoped and conservative for the same reason as `revoked_among/2`: a run-id this board does
  not own is NOT returned (the slot stays bound rather than freeing on an id we cannot verify), and
  a non-integer id is ignored rather than raising — a heartbeat must never 500. Empty in → empty out.
  """
  def terminal_among(%Board{id: board_id}, bound_run_ids) when is_list(bound_run_ids) do
    ids = for id <- bound_run_ids, int = to_job_id(id), is_integer(int), do: int

    case ids do
      [] ->
        []

      ids ->
        Repo.all(
          from r in Run,
            join: c in Card,
            on: c.id == r.card_id,
            where:
              c.board_id == ^board_id and r.id in ^ids and
                r.status in ^Run.terminal_statuses(),
            select: %{id: r.id, status: r.status}
        )
    end
  end

  def terminal_among(_board, _ids), do: []

  defp to_job_id(id) when is_integer(id), do: id

  defp to_job_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_job_id(_), do: nil

  @doc """
  The board's node-job `id` (integer or numeric string — the controller hands
  in a raw path param) resolved against its claim state:

    * `{:ok, job}` — held by a live claim (`state in NodeJob.claimed_states/0`).
    * `{:already_finalized, run}` — the job is already `:done`; a duplicate/stray
      outcome POST for it is first-writer-wins (RLY-202), so the controller answers
      success with the run's recorded state rather than a conflict.
    * `{:error, :not_found}` — no such job on the board, or `id` isn't a valid integer.
    * `{:error, :conflict}` — it exists but is `:queued` (reassigned) or `:revoked`
      (zombie), so a stale executor cannot clobber it.
  """
  def get_claimed_job(%Board{} = board, id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> get_claimed_job(board, int_id)
      _invalid -> {:error, :not_found}
    end
  end

  def get_claimed_job(%Board{id: board_id}, id) when is_integer(id) do
    job =
      Repo.one(
        from j in NodeJob,
          join: r in Run,
          on: r.id == j.run_id,
          join: c in Card,
          on: c.id == r.card_id,
          # A talk job can never be reported through POST /api/node-jobs/:id/outcome — it has
          # no run to attach an outcome to, and the inner join on Run already excludes it (a
          # talk job's run_id is nil); this filter makes that exclusion explicit.
          where: j.id == ^id and c.board_id == ^board_id and j.kind in ^NodeJob.flow_kinds()
      )

    cond do
      is_nil(job) -> {:error, :not_found}
      job.state in NodeJob.claimed_states() -> {:ok, job}
      job.state == :done -> {:already_finalized, Repo.get!(Run, job.run_id)}
      true -> {:error, :conflict}
    end
  end

  @executor_stale_floor_s 60

  @doc """
  The reclaim sweep (criterion 2): for every stale executor, return its in-flight
  `shared_clean` jobs to `queued` (dropping `executor_name`, so W8 re-offers them)
  and park its `exclusive` runs (`parked_reason: :executor_gone` — affinity is
  absolute; the run waits for its machine). Idempotent; `now` is injectable for
  the reaper's clock and tests.
  """
  def reclaim_stale_executors(now \\ nil) do
    now = now || now()

    Executor
    |> Repo.all()
    |> Enum.filter(&executor_stale?(&1, now))
    |> Enum.each(&reclaim_executor/1)

    :ok
  end

  @doc "True when `executor` has been silent past `max(60s, 2 × interval)` at `now`. Pure."
  def executor_stale?(%Executor{last_heartbeat: at, interval: interval}, %DateTime{} = now) do
    DateTime.diff(now, at, :second) > max(@executor_stale_floor_s, 2 * (interval || 30))
  end

  @doc """
  The executor's freshness at `now`: `:fresh | :stale | :gone`. Pure.

  `:gone` is deliberately *the same predicate the reaper uses* (`executor_stale?/2`) rather
  than a second invented threshold — so a `gone` row on the runners view means the executor's
  in-flight work has been requeued or parked, not merely that a beat looks late.
  """
  def executor_freshness(%Executor{last_heartbeat: at, interval: interval} = executor, %DateTime{} = now) do
    age = DateTime.diff(now, at, :second)

    cond do
      age <= 1.5 * (interval || 30) -> :fresh
      executor_stale?(executor, now) -> :gone
      true -> :stale
    end
  end

  # A machine silent for a day is history, not roster (the retention the runners view has
  # always applied). Display-only — the reaper owns row lifecycle, and this function deletes
  # nothing.
  @roster_window_s 86_400

  @doc """
  The runners-view roster for `board` at `now` — one map per executor, sorted by name, each
  carrying its advertised capacity (with `used` counted from that executor's active jobs) and
  the in-flight jobs attributed to it.

  Pure w.r.t. the clock: `now` is injectable and defaults to the current time. Two queries,
  no N+1. Reads only Postgres, so the page survives an app restart — unlike `Runs.Capacity`,
  which is ETS and scheduler-only.
  """
  def list_executor_status(%Board{} = board, now \\ nil) do
    now = now || now()
    cutoff = DateTime.add(now, -@roster_window_s, :second)

    executors =
      Repo.all(
        from e in Executor,
          where: e.board_id == ^board.id and e.last_heartbeat > ^cutoff,
          order_by: [asc: e.name]
      )

    jobs_by_executor = active_jobs_by_executor(board)

    Enum.map(executors, fn executor ->
      jobs = Map.get(jobs_by_executor, executor.name, [])
      freshness = executor_freshness(executor, now)
      outdated = executor_outdated?(executor)

      %{
        id: executor.id,
        name: executor.name,
        host: executor.host,
        interval: executor.interval || 30,
        last_heartbeat: executor.last_heartbeat,
        freshness: freshness,
        version: executor.version,
        # Orthogonal to `freshness` on purpose (RLY-184): a refused executor is perfectly
        # healthy and beating normally — it is just running old code.
        outdated: outdated,
        # RLY-191: the single presentation state the runners view renders from. Precedence
        # :gone > :stale > :outdated > :fresh — a silent executor's silence is the more urgent
        # fact than its version. Derived, never stored; `freshness` keeps heartbeat truth.
        display_state: display_state(freshness, outdated),
        pools: pools_for(executor, jobs),
        jobs: jobs
      }
    end)
  end

  defp display_state(:gone, _outdated), do: :gone
  defp display_state(:stale, _outdated), do: :stale
  defp display_state(:fresh, true), do: :outdated
  defp display_state(:fresh, false), do: :fresh

  @doc ~S"""
  The board's **active queue** at `now` — every `queued` or `claimed` node job on the board, both
  kinds (`:node` and `:talk`), whether or not an executor holds it. The read-only answer to "what
  is waiting?" that `POST /api/node-jobs/claim` — a mutation that *assigns* the job it finds —
  cannot give (RE307).

  Deliberately NOT filtered by `executor_name`: an unclaimed job having no holder is the whole
  point, and that filter is exactly why `active_jobs_by_executor/1` cannot answer this. Both
  reads share `board_jobs_query/1`, whose LEFT join on `Run` is what lets a talk turn (no run —
  ADR 0009) appear here at all.

  **Ordering is load-bearing, not cosmetic.** Queued rows come first in `asc: j.id` — the same
  order `do_claim_next_job/4` claims in under `FOR UPDATE SKIP LOCKED` — so this list literally IS
  the order the server will hand work out. Claimed rows follow in `asc: j.claimed_at`, matching
  `active_jobs_by_executor/1`. A single `asc_nulls_first: j.claimed_at, asc: j.id` expresses both,
  because a queued row never has a `claimed_at` (`requeue_job/3` clears it on the way back), and
  that holds for a queued row PINNED to an executor too.

  `age_s` is "how long it has been in THIS state" — since `claimed_at` on a claimed row, since
  `inserted_at` on a queued one. `now` is injectable exactly as `list_executor_status/2` does it,
  so age is testable without sleeping.
  """
  @spec list_queue(Board.t(), DateTime.t() | nil) :: [
          %{
            job_id: integer(),
            kind: :node | :talk,
            state: :queued | :claimed,
            ref: String.t(),
            title: String.t(),
            node_key: String.t(),
            flow_key: String.t() | nil,
            isolation: String.t() | nil,
            executor_name: String.t() | nil,
            age_s: non_neg_integer()
          }
        ]
  def list_queue(%Board{} = board, now \\ nil) do
    now = now || now()

    board
    |> board_jobs_query()
    |> order_by([j], asc_nulls_first: j.claimed_at, asc: j.id)
    |> select([j, c, r], %{
      job_id: j.id,
      kind: j.kind,
      state: j.state,
      ref_number: c.ref_number,
      title: c.title,
      node_key: j.node_key,
      flow_key: r.flow_key,
      isolation: fragment("?->>'isolation'", j.payload),
      executor_name: j.executor_name,
      claimed_at: j.claimed_at,
      inserted_at: j.inserted_at
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        job_id: row.job_id,
        kind: row.kind,
        state: row.state,
        ref: Cards.ref(board, %Card{ref_number: row.ref_number}),
        title: row.title,
        node_key: row.node_key,
        flow_key: row.flow_key,
        isolation: row.isolation,
        executor_name: row.executor_name,
        age_s: max(DateTime.diff(now, row.claimed_at || row.inserted_at), 0)
      }
    end)
  end

  @doc "The board's raw `Executor` rows — the lean read `Scheduler.Server` builds its snapshot's `executors` map from."
  def list_board_executors(board_id) do
    Repo.all(from e in Executor, where: e.board_id == ^board_id)
  end

  ## Resume refusals (RE297)

  @doc """
  Records the scheduler's refused resumes for `board_id` as facts on the run rows.

  `refusals` is `Relay.Runs.Scheduler.Plan`'s `refusals` list — every run whose resume
  `Policy.resumable?/2` allowed and `Scheduler.take_slot/3` could not place on this tick.

  `resume_refused_since` is stamped **only when it is currently nil**, so the column measures a
  CONTINUOUS refusal rather than the latest tick; a reason that changes mid-refusal updates the
  reason and keeps the original `since`. Every OTHER active run on the board has both columns
  cleared, so a run that resumed — or that stopped being refused for any other reason — never
  carries a stale clock into `abandon_unresumable_runs/1`.

  Steady state is a single SELECT that returns nothing: the values are already at their target,
  so a quiet board writes no rows per tick. `now` is injectable for tests.
  """
  def record_resume_refusals(board_id, refusals, now \\ nil) do
    now = now || now()
    Enum.each(refusals, &stamp_refusal(&1, now))
    clear_stale_refusals(board_id, Enum.map(refusals, & &1.run_id))
    :ok
  end

  # Two guarded UPDATEs by primary key, each a no-op once the row already says this. Splitting
  # them is what lets `since` be write-once while `reason` tracks the current cause.
  defp stamp_refusal(%{run_id: run_id, reason: reason}, now) do
    Repo.update_all(
      from(r in Run, where: r.id == ^run_id and is_nil(r.resume_refused_since)),
      set: [resume_refused_since: now]
    )

    Repo.update_all(
      from(r in Run,
        where: r.id == ^run_id,
        where: is_nil(r.resume_refused_reason) or r.resume_refused_reason != ^reason
      ),
      set: [resume_refused_reason: reason]
    )
  end

  # Board-scoped, and only over runs that actually carry a stamp — so the common case (nothing
  # is being refused) is one indexed SELECT returning zero rows and no UPDATE at all.
  defp clear_stale_refusals(board_id, refused_ids) do
    stamped =
      Repo.all(
        from r in Run,
          join: c in Card,
          on: c.id == r.card_id,
          where: c.board_id == ^board_id,
          where: r.status in ^Run.active_statuses(),
          where: not is_nil(r.resume_refused_since) or not is_nil(r.resume_refused_reason),
          select: r.id
      )

    case stamped -- refused_ids do
      [] ->
        :ok

      ids ->
        Repo.update_all(from(r in Run, where: r.id in ^ids),
          set: [resume_refused_since: nil, resume_refused_reason: nil]
        )

        :ok
    end
  end

  ## Diagnosis (RLY-177)

  # A job that has sat queued or claimed this long with nothing alive behind it is
  # stranded, not merely slow. Deliberately well above the executor grace floor
  # (`@executor_stale_floor_s`) so a single missed beat never reads as stranded.
  @stranded_grace_s 300

  # A board with jobs queued unclaimed this long is stopped, not merely between claims —
  # deliberately far below the ~20m the RLY-191 incident ran and far above a normal ~5s
  # executor poll. Jobs queued only because every executor is legitimately busy return nil.
  @stopped_work_after_s 120

  @doc """
  The board-level "work has stopped" verdict, or `nil` when the board is quiet. Non-`nil` only
  when: at least one node-job is queued and unclaimed, the oldest has waited past
  `@stopped_work_after_s`, AND the shared `Scheduler.capacity_diagnosis/1` blames the roster
  (outdated / no executor / all gone) rather than a legitimately busy board. `now` is injectable.
  """
  @spec stopped_work(Board.t(), DateTime.t() | nil) ::
          nil
          | %{
              reason: :executor_outdated | :no_executor | :executor_gone,
              detail: String.t(),
              queued_count: pos_integer(),
              oldest_queued_age_s: pos_integer(),
              evidence: map()
            }
  def stopped_work(%Board{} = board, now \\ nil) do
    now = now || now()

    case queued_jobs_summary(board) do
      nil ->
        nil

      %{count: count, oldest_inserted_at: oldest} ->
        age = DateTime.diff(now, oldest, :second)

        # The age guard comes FIRST on purpose: this is polled on the Runners view's 10s tick,
        # and the snapshot behind `roster_verdict/3` is the expensive half (a full card list plus
        # stage/flow/run/executor reads). A board with work merely in flight must not pay for a
        # snapshot every tick — only one queued past the threshold, where the answer can be non-nil.
        if age > @stopped_work_after_s, do: roster_verdict(board, count, age)
    end
  end

  # Does the shared capacity diagnosis blame the roster rather than a legitimately busy board?
  defp roster_verdict(%Board{} = board, count, age) do
    {snapshot, _cards_by_id} = SchedulerServer.build_snapshot(board.id, SchedulerServer.configured_engine())
    {reason, bits} = Scheduler.capacity_diagnosis(snapshot)

    if reason in [:executor_outdated, :no_executor, :executor_gone] do
      %{
        reason: reason,
        detail: stopped_work_detail(reason, bits, age),
        queued_count: count,
        oldest_queued_age_s: age,
        evidence: bits
      }
    end
  end

  defp queued_jobs_summary(%Board{} = board) do
    row =
      Repo.one(
        from j in NodeJob,
          join: r in Run,
          on: r.id == j.run_id,
          join: c in Card,
          on: c.id == r.card_id,
          where: c.board_id == ^board.id and j.state == :queued,
          # Explicit: "work has stopped" is a FLOW diagnosis — a talk job queued because no
          # executor is connected is a separate, not-yet-built story, and the inner join on
          # Run already excludes it.
          where: j.kind in ^NodeJob.flow_kinds(),
          select: %{count: count(j.id), oldest: min(j.inserted_at)}
      )

    case row do
      %{count: 0} -> nil
      %{count: count, oldest: oldest} -> %{count: count, oldest_inserted_at: oldest}
    end
  end

  defp stopped_work_detail(:executor_outdated, bits, age) do
    "No jobs claimed in #{div(age, 60)}m · every connected executor is running old code and is " <>
      "being refused — #{Scheduler.running_versions_phrase(bits)}, requires v#{bits.required_version}. " <>
      "Restart it to pick up current code."
  end

  defp stopped_work_detail(reason, _bits, age) when reason in [:no_executor, :executor_gone] do
    "No jobs claimed in #{div(age, 60)}m · no executor is connected to run this board's work."
  end

  @doc """
  Why `card` is or is not moving: `%{verdict, detail, evidence}`.

  The thin facade the web layer uses — `Relay.Runs` exports only `[Supervisor, Capacity,
  SchedulerSupervisor]` (`use Boundary` above), so `RelayWeb` cannot reach
  `Relay.Runs.Scheduler` and must not know it exists. The dispatch verdicts come from
  `Scheduler.explain/2` over the **same snapshot the scheduler plans from**
  (`Scheduler.Server.build_snapshot/2`); this function layers on the two verdicts that
  need DB state the snapshot does not carry — `:run_failed` (the card has no active run
  and its latest run failed) and `:job_stranded` (an active job past `@stranded_grace_s`
  with no live executor).

  Read-only: safe to call while a run is live. `now` is injectable for tests.
  """
  @spec diagnose(Board.t(), Card.t(), DateTime.t() | nil) :: %{verdict: atom(), detail: String.t(), evidence: map()}
  def diagnose(%Board{} = board, %Card{} = card, now \\ nil) do
    now = now || now()
    {snapshot, _cards_by_id} = SchedulerServer.build_snapshot(board.id, SchedulerServer.configured_engine())

    run = active_run(card)
    last = latest_run(card)
    job = run && active_job(run)
    capacity = Scheduler.capacity_diagnosis(snapshot)

    snapshot
    |> Scheduler.explain(card.id)
    |> put_evidence(:current_node, run && run.current_node)
    |> put_evidence(:last_execution, last_execution_summary(last))
    |> put_evidence(:job, job_summary(job))
    |> layer_pin_freshness(board, now)
    |> override_verdict(run, last, job, board, now, capacity)
  end

  defp override_verdict(base, run, last, job, board, now, capacity) do
    cond do
      run != nil and stranded?(job, board, now) ->
        stranded_verdict(base, job)

      run != nil and roster_blocked?(run, job, board, now, capacity) ->
        roster_blocked_verdict(base, capacity)

      run == nil and last != nil and last.status == :failed ->
        run_failed_verdict(base, last)

      true ->
        base
    end
  end

  # For a parked pinned run, explain/2 has already named the awaited executor in the
  # detail sentence and stamped evidence.pinned_executor_name. The snapshot can't know
  # whether that machine is connected RIGHT NOW, so layer the live freshness on here —
  # the same way current_node is layered from DB state the snapshot lacks.
  defp layer_pin_freshness(%{evidence: %{pinned_executor_name: name}} = base, board, now) when is_binary(name) do
    {label, sentence} = executor_freshness_note(board, name, now)

    %{
      base
      | detail: base.detail <> " " <> sentence,
        evidence: Map.put(base.evidence, :pinned_executor_freshness, label)
    }
  end

  defp layer_pin_freshness(base, _board, _now), do: base

  defp executor_freshness_note(board, name, now) do
    case Repo.get_by(Executor, board_id: board.id, name: name) do
      nil ->
        {:absent, ~s(Executor "#{name}" is not currently connected.)}

      executor ->
        case executor_freshness(executor, now) do
          :fresh -> {:fresh, ~s(Executor "#{name}" is connected and beating.)}
          :stale -> {:stale, ~s(Executor "#{name}" is connected but a heartbeat is overdue.)}
          :gone -> {:gone, ~s(Executor "#{name}" has gone silent past the stale threshold.)}
        end
    end
  end

  # A live run whose current job is NOT being worked (queued/unclaimed, or held by a silent
  # executor) while the roster reason is "everyone refused / nobody connected" — the RLY-191
  # false-"working" case explain/2 can't see, because run != nil short-circuits it to
  # :run_active. A busy-but-healthy roster (:awaiting_capacity) is deliberately excluded.
  #
  # A :parked run never hits this: run_verdict/2 already gives it the correct, specific
  # verdict (never :run_active), so there is no "false working" claim to correct — and for
  # a parked *pinned* run (RLY-199) that verdict names the awaited machine, which this
  # generic roster message would otherwise clobber.
  defp roster_blocked?(%{status: :parked}, _job, _board, _now, _capacity), do: false

  defp roster_blocked?(_run, job, board, now, {reason, _bits}) do
    reason in [:executor_outdated, :no_executor, :executor_gone] and not job_working?(job, board, now)
  end

  defp job_working?(%NodeJob{state: state, executor_name: name}, board, now) when is_binary(name) do
    with true <- state in NodeJob.claimed_states(),
         %Executor{} = executor <- Repo.get_by(Executor, board_id: board.id, name: name) do
      not executor_stale?(executor, now)
    else
      _not_working -> false
    end
  end

  defp job_working?(_job, _board, _now), do: false

  defp roster_blocked_verdict(base, {:executor_outdated, bits}) do
    %{
      base
      | verdict: :executor_outdated,
        detail:
          "This run's node-job is queued but unclaimed — every connected executor is running old " <>
            "code and is being refused (#{Scheduler.running_versions_phrase(bits)}, " <>
            "requires v#{bits.required_version}). Restart it to pick up current code.",
        evidence: Map.merge(base.evidence, bits)
    }
  end

  defp roster_blocked_verdict(base, {reason, bits}) when reason in [:no_executor, :executor_gone] do
    %{
      base
      | verdict: :no_executor,
        detail: "This run's node-job is queued but no executor is connected to claim it.",
        evidence: Map.merge(base.evidence, bits)
    }
  end

  defp stranded_verdict(base, job) do
    %{
      base
      | verdict: :job_stranded,
        detail:
          "Job #{job.id} for node #{job.node_key} has been #{job.state} since " <>
            "#{job.claimed_at || job.inserted_at} and no live executor#{executor_suffix(job.executor_name)}" <>
            " is holding it — the run is stuck, not working."
    }
  end

  defp executor_suffix(nil), do: ""
  defp executor_suffix(name), do: " (#{name})"

  defp run_failed_verdict(base, last) do
    %{
      base
      | verdict: :run_failed,
        detail:
          "Run #{last.id} failed at node #{last_node(last) || "?"}. " <>
            "The full failure detail is in evidence.last_execution.detail."
    }
  end

  defp put_evidence(base, key, value), do: %{base | evidence: Map.put(base.evidence, key, value)}

  # A job is stranded when it is old enough to rule out normal latency AND the executor
  # named on it is stale (or nothing is named and nothing on this board is fresh).
  # Reuses `executor_stale?/2` rather than inventing a second threshold, so "stranded"
  # can never disagree with what the reclaim sweep would act on. A claimed job under a
  # live executor needs no special clause — `any_live_executor?/3` already excludes it.
  defp stranded?(nil, _board, _now), do: false

  defp stranded?(%NodeJob{} = job, board, now) do
    age = DateTime.diff(now, job.claimed_at || job.inserted_at, :second)
    age > @stranded_grace_s and not any_live_executor?(job, board, now)
  end

  defp any_live_executor?(%NodeJob{executor_name: nil}, board, now) do
    Executor
    |> where([e], e.board_id == ^board.id)
    |> Repo.all()
    |> Enum.any?(&(not executor_stale?(&1, now)))
  end

  defp any_live_executor?(%NodeJob{executor_name: name}, board, now) do
    case Repo.get_by(Executor, board_id: board.id, name: name) do
      nil -> false
      executor -> not executor_stale?(executor, now)
    end
  end

  defp last_execution_summary(%Run{node_executions: executions}) when is_list(executions) do
    case List.last(executions) do
      nil ->
        nil

      execution ->
        %{
          node_key: execution.node_key,
          outcome: execution.outcome,
          detail: execution.detail,
          attempt: execution.attempt,
          visit: execution.visit
        }
    end
  end

  defp last_execution_summary(_run), do: nil

  defp last_node(run) do
    case last_execution_summary(run) do
      nil -> nil
      %{node_key: node_key} -> node_key
    end
  end

  defp job_summary(nil), do: nil

  defp job_summary(%NodeJob{} = job) do
    %{
      id: job.id,
      state: job.state,
      node_key: job.node_key,
      executor_name: job.executor_name,
      claimed_at: job.claimed_at
    }
  end

  @doc """
  Readiness snapshot for `flow` — "if I turn this on, will it work?" (RLY-182). See
  `Relay.Runs.Preflight` for the candidate rules; read-only, and safe on the render path.
  """
  defdelegate preflight_flow(flow, now \\ nil), to: Preflight, as: :run

  # The ONE board-scoped read of LIVE node jobs, shared by `list_queue/2` and
  # `active_jobs_by_executor/1` so the two can never disagree about what "on this board and
  # still live" means. Each caller adds its own filters, order and select.
  #
  # `Card` is joined on `j.card_id` — the board-scoping join for BOTH kinds, since `card_id` is
  # required on every row while `run_id` is nil on a talk turn (ADR 0009). `insert_job!/3` writes
  # `card_id: run.card_id`, so a flow job resolves the same card it always did.
  #
  # `Run` is **LEFT**-joined, and only for `flow_key`: an inner join here is the exact bug that
  # makes every other queue read flow-only. `active_jobs_by_executor/1` is unaffected because its
  # own `flow_kinds()` filter already guarantees `run_id` is non-nil.
  defp board_jobs_query(%Board{id: board_id}) do
    from j in NodeJob,
      join: c in Card,
      on: c.id == j.card_id,
      left_join: r in Run,
      on: r.id == j.run_id,
      where: c.board_id == ^board_id,
      where: j.state in ^NodeJob.active_states()
  end

  # Every active job on this board that some executor is holding, grouped by `executor_name`.
  # Board-scoped by the shared base query, so one executor name shared across boards never leaks
  # work sideways.
  defp active_jobs_by_executor(%Board{} = board) do
    board
    |> board_jobs_query()
    |> where([j], not is_nil(j.executor_name))
    # Explicit: the runners view's per-executor job list is FLOW jobs only (step 1). Now that the
    # shared base LEFT-joins Run, this filter is the ONLY thing excluding talk jobs — it must stay.
    |> where([j], j.kind in ^NodeJob.flow_kinds())
    |> order_by([j], asc: j.claimed_at, asc: j.id)
    |> select([j, c], %{
      executor_name: j.executor_name,
      job_id: j.id,
      ref_number: c.ref_number,
      title: c.title,
      node_key: j.node_key,
      state: j.state,
      isolation: fragment("?->>'isolation'", j.payload),
      claimed_at: j.claimed_at
    })
    |> Repo.all()
    |> Enum.group_by(& &1.executor_name, fn row ->
      %{
        job_id: row.job_id,
        ref: Cards.ref(board, %Card{ref_number: row.ref_number}),
        title: row.title,
        node_key: row.node_key,
        state: row.state,
        isolation: row.isolation,
        claimed_at: row.claimed_at
      }
    end)
  end

  # One chip per ADVERTISED class — we never invent a chip for capacity the executor never
  # claimed to have. `used` counts that executor's active jobs in the class, treating any
  # non-"exclusive" isolation as shared_clean (the same rule reclaim_executor/1 applies).
  defp pools_for(%Executor{capacity: capacity}, jobs) do
    used = Enum.frequencies_by(jobs, &isolation_class(&1.isolation))

    capacity
    |> Enum.sort_by(fn {name, _total} -> name end)
    |> Enum.map(fn {name, total} ->
      %{name: name, used: Map.get(used, name, 0), total: total}
    end)
  end

  defp isolation_class("exclusive"), do: "exclusive"
  defp isolation_class(_shared), do: "shared_clean"

  defp reclaim_executor(%Executor{board_id: board_id, name: name}) do
    rows =
      Repo.all(
        from j in NodeJob,
          join: r in Run,
          on: r.id == j.run_id,
          join: c in Card,
          on: c.id == r.card_id,
          where: c.board_id == ^board_id and j.executor_name == ^name and j.state in ^NodeJob.active_states(),
          # Explicit: a stale executor's talk turn is a separate recovery story (it stays
          # claimed until a human presses Stop — see requeue_orphaned_jobs/3's step-1 note),
          # and the inner join on Run already excludes it.
          where: j.kind in ^NodeJob.flow_kinds(),
          select: {j, r, c.id}
      )

    Enum.each(rows, fn {job, run, card_id} ->
      case job.payload["isolation"] do
        "exclusive" -> park_for_reclaim(run)
        _shared -> requeue_job(job, board_id, card_id)
      end
    end)
  end

  @doc """
  Requeues jobs this executor is holding but is no longer running (RLY-170).

  An executor that restarts loses its in-flight job state — it lives in-process — while the
  job stays `:claimed` server-side. Neither existing recovery path can see it:
  `claim_next_job/1` only ever offers `:queued` jobs, and `reclaim_stale_executors/0` only
  touches a **stale** executor, whereas a restarted one is alive and beating. So the job sat
  stranded forever, the run stuck on that node, with nothing reporting a problem.

  The heartbeat already tells us which jobs the executor IS running, so the **absence** of one
  from that list is the signal. Two things make this safe:

    * **A grace window.** A job claimed moments before a beat is legitimately not in `running`
      yet; requeuing it would double-dispatch LIVE work, which is worse than the bug. Jobs
      claimed more recently than `max(60s, 2 × interval)` — the same threshold shape as
      `executor_stale?/2`, and provably longer than a beat — are left alone.
    * **Exclusive jobs stay pinned.** The run's commits live in *that* machine's worktree, so
      recovery must land back on the same executor. Keeping `executor_name` routes it there via
      the pinned-claim path (RLY-135), which bypasses the advertised-capacity filter. Only
      `shared_clean` jobs are unpinned, since any executor can pick those up.

  **Known step-1 limitation (RE268 / ADR 0009):** a TALK turn is never requeued here — the
  query below is explicitly `kind in NodeJob.flow_kinds()`. Requeueing a talk job would hand a
  resumed `claude` session to a machine that does not hold it, so a turn whose executor dies
  stays `claimed` until a human presses Stop (`Relay.Runs.revoke_talk_job/1` revokes
  unconditionally).
  """
  def requeue_orphaned_jobs(%Board{id: board_id}, %Executor{} = executor, running_ids) do
    held = for id <- running_ids, int = to_job_id(id), is_integer(int), do: int
    cutoff = DateTime.add(now(), -orphan_grace_s(executor), :second)

    from(j in NodeJob,
      join: r in Run,
      on: r.id == j.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^board_id,
      where: j.executor_name == ^executor.name,
      where: j.state in ^NodeJob.active_states(),
      where: not is_nil(j.claimed_at) and j.claimed_at < ^cutoff,
      where: j.kind in ^NodeJob.flow_kinds(),
      select: {j, c.id}
    )
    |> Repo.all()
    |> Enum.reject(fn {job, _card_id} -> job.id in held end)
    |> Enum.each(fn {job, card_id} -> requeue_orphan(job, executor, board_id, card_id) end)

    :ok
  end

  defp orphan_grace_s(%Executor{interval: interval}) do
    max(@executor_stale_floor_s, 2 * (interval || 30))
  end

  defp requeue_orphan(%NodeJob{} = job, %Executor{name: name}, board_id, card_id) do
    keep_pin = if job.payload["isolation"] == "exclusive", do: name

    Repo.update_all(
      from(j in NodeJob, where: j.id == ^job.id and j.state in ^NodeJob.active_states()),
      set: [state: :queued, executor_name: keep_pin, claimed_at: nil]
    )

    broadcast_runs(board_id, {:run_changed, card_id})
    :ok
  end

  defp requeue_job(%NodeJob{} = job, board_id, card_id) do
    {1, _} =
      Repo.update_all(
        from(j in NodeJob, where: j.id == ^job.id and j.state in ^NodeJob.active_states()),
        set: [state: :queued, executor_name: nil, claimed_at: nil]
      )

    broadcast_runs(board_id, {:run_changed, card_id})
    :ok
  end

  @doc false
  # Revokes any lingering active job regardless of the run's current status
  # FIRST — the job that triggered this reclaim must never stay stuck
  # :claimed under a dead executor's name, even if the run itself
  # already moved on (e.g. parked/finished via a concurrent path) by the time
  # this runs — then, only for a still-:running run, flips it to
  # :parked/:executor_gone (affinity is absolute; the run waits for its
  # machine).
  def park_for_reclaim(%Run{} = run) do
    stop_server(run)
    run = Repo.get!(Run, run.id)

    revoke_active_jobs(run)

    case Transitions.transition(run, [:running], :parked, set: [parked_reason: :executor_gone]) do
      {:ok, updated} -> broadcast_runs(board_id_of(updated), {:run_parked, updated})
      {:error, :not_in_expected_state} -> :ok
    end

    :ok
  end

  ## Seams for the RunServer, the Listener (Task 3), and the boot resumer.
  ## @doc false: internal engine plumbing, not public context API.

  @doc false
  def resume_run(%Run{} = run, opts \\ []) do
    case Transitions.transition(run, [:parked], :running,
           set: [parked_reason: nil, resume_refused_since: nil, resume_refused_reason: nil]
         ) do
      {:ok, updated} ->
        broadcast_runs(board_id_of(updated), {:run_resumed, updated})
        {:ok, _pid} = ensure_server(updated, {:reenter, Keyword.get(opts, :resume_session)})
        {:ok, updated}

      {:error, :not_in_expected_state} ->
        {:error, :not_parked}
    end
  end

  @doc """
  Re-enters a terminally FAILED run inside its flow (RLY-189), at the node that
  died — or at `opts[:at]` — with the run's branch, worktree, history and
  executor pin intact.

  This revives the dead run rather than starting a new one, because re-entry
  (`RunServer.handle_continue({:reenter, _})`) never consults the flow's start
  edge: the Code flow's destructive `branch` node is unreachable from here by
  construction, so finished commits cannot be thrown away. `close_run!/3` nils
  `current_node` on every terminal close, so the default target is recovered
  from the run's most recent `NodeExecution`.

  `opts[:at]` re-enters a DIFFERENT node on a fresh visit at attempt 1 (a
  same-visit re-entry would corrupt per-visit retry accounting). It must name a
  node in the flow; `"start"`/`"done"` are edge sentinels, not nodes, so they
  are refused like any unknown key.

  Every cap the engine consults is raised by `retries` (see
  `Relay.Runs.Engine`), so a retry buys exactly one more move — never a reset.

  Refusals: `{:not_failed, status}`, `:active_run_exists`, `:no_flow`,
  `{:unknown_node, key}`, `{:executor_unavailable, name}`. Each pairs with a
  token from `retry_refusal_code/1` and a sentence from
  `retry_refusal_message/1`.
  """
  def retry_run(%Run{} = run, opts \\ []) do
    with :ok <- check_retryable(run),
         :ok <- check_no_active_run(run),
         {:ok, flow} <- load_flow(run),
         {:ok, node, mode} <- resolve_retry_target(run, flow, Keyword.get(opts, :at)),
         :ok <- check_retry_executor(run, flow) do
      revive_run(run, node, mode, Keyword.get(opts, :actor, :agent))
    end
  end

  defp check_retryable(%Run{} = run) do
    cond do
      restartable?(run) -> :ok
      awaiting_human_answer?(run) -> {:error, :awaiting_answer}
      true -> {:error, {:not_failed, run.status}}
    end
  end

  @doc """
  Which kind of `needs_input` park this is — the ONE place park provenance is decided (RE253).

    * `:question`   — the node reported `:needs_input`; a human is being asked something (A1).
    * `:escalation` — a `--on failed --> needs_input` edge routed a node failure to a human (A4).
    * `nil`         — not a `needs_input` park.

  The inference is exact, so no schema column is needed to tell the two apart: a `:needs_input`
  outcome parks in `Relay.Runs.Engine.decide/4` *before* edge routing is ever reached, so the two
  cases can never collide. See `docs/architecture/failures.md` (A1 vs A4).

  The 3-arity form exists because `restartable_runs/1` reads latest outcomes in ONE grouped query
  and must classify without a per-run round trip; the 1-arity form is the convenience wrapper.
  """
  def park_kind(:parked, :needs_input, :needs_input), do: :question
  def park_kind(:parked, :needs_input, _outcome), do: :escalation
  def park_kind(_status, _parked_reason, _outcome), do: nil

  def park_kind(%Run{status: status, parked_reason: parked_reason} = run),
    do: park_kind(status, parked_reason, latest_execution_outcome(run))

  # A genuine human question, not an escalated node failure. The one non-restartable state retry
  # names by itself, so a human is told to answer it rather than "restart" it (RLY-228).
  defp awaiting_human_answer?(%Run{} = run), do: park_kind(run) == :question

  @doc """
  Whether `run` itself stalled in a way retry can revive in place — the ONE per-RUN eligibility
  rule, used directly by per-run retry (`check_retryable/1`). True for a clean `:failed` run, and
  for an escalation park (`park_kind/3 == :escalation` — a node failure routed to a human,
  RLY-194/A4). False for a genuine `:needs_input` question, any `:executor_gone` park (RLY-199
  auto-resumes those), and `:running`/`:done`/`:cancelled`.

  The board-scoped consumers — the bulk sweep (`restart_stalled/2`), the board's stalled badge
  (`restartable_count/1`), and the restart dialog (`stalled_cards/1`) — all read this same rule
  through `restartable_runs/1`, which ADDITIONALLY excludes cards already in a terminal-type
  stage (`Stage.terminal_types/0`, RE247): a run can be `restartable?/1` true while its card has
  since moved to Done, and the board-scoped consumers correctly skip it where this function
  cannot (it only sees the run).
  """
  def restartable?(%Run{status: status, parked_reason: parked_reason} = run),
    do: restartable_by_outcome?(status, parked_reason, latest_execution_outcome(run))

  # The eligibility rule, expressed exactly once (AGENTS.md "a magic value is defined once"):
  # a run is revivable-in-place iff it FAILED cleanly, or its park was an escalated node failure.
  # Park provenance itself is not re-derived here — `park_kind/3` owns that.
  defp restartable_by_outcome?(:failed, _parked_reason, _latest_outcome), do: true

  defp restartable_by_outcome?(status, parked_reason, latest_outcome),
    do: park_kind(status, parked_reason, latest_outcome) == :escalation

  @doc "The `outcome` of `run`'s most recent NodeExecution, or nil when it has none."
  def latest_execution_outcome(%Run{id: run_id}) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run_id,
        order_by: [desc: e.id],
        limit: 1,
        select: e.outcome
    )
  end

  # The partial unique index runs_one_active_per_card_index would reject the revival
  # anyway; refusing here turns a constraint error into a sentence a human can act on.
  defp check_no_active_run(%Run{card_id: card_id, id: id}) do
    active? =
      Repo.exists?(from r in Run, where: r.card_id == ^card_id and r.id != ^id and r.status in ^Run.active_statuses())

    if active?, do: {:error, :active_run_exists}, else: :ok
  end

  defp resolve_retry_target(run, flow, nil) do
    case last_executed_node(run) do
      nil -> {:error, {:unknown_node, "(none)"}}
      node -> validate_node_in_flow(node, flow, {:reenter, nil})
    end
  end

  defp resolve_retry_target(_run, flow, at) when is_binary(at) do
    validate_node_in_flow(at, flow, {:reenter_new_visit, nil})
  end

  # `at` arrives straight off a JSON body, so it can be any term. Anything that
  # is not a node key is refused with the same closed vocabulary the endpoint
  # documents — never a raise, which `action_fallback` cannot turn into a 422.
  defp resolve_retry_target(_run, _flow, at), do: {:error, {:unknown_node, inspect(at)}}

  # Flow definitions are mutable in place (`Relay.Flows.update_flow/2`,
  # `save_definition/2`), so a node key that existed when this run failed can
  # be gone by the time a human retries. Both retry targets — the recovered
  # last-executed node and an explicit `--at` — must be checked against the
  # CURRENT flow, or a revived run can enter `RunServer` pointed at a node
  # that no longer exists and crash asynchronously after `{:ok, run}` already
  # reported success.
  defp validate_node_in_flow(node, flow, mode) do
    if Enum.any?(flow.nodes, &(&1.key == node)) do
      {:ok, node, mode}
    else
      {:error, {:unknown_node, node}}
    end
  end

  defp last_executed_node(%Run{id: run_id}) do
    Repo.one(from e in NodeExecution, where: e.run_id == ^run_id, order_by: [desc: e.id], limit: 1, select: e.node_key)
  end

  # Worktrees are executor-side state Phoenix cannot see, so the one thing the server
  # CAN check is whether the machine holding this run's worktree is still there. An
  # exclusive run pinned to an absent executor would queue a job nothing can claim.
  defp check_retry_executor(%Run{} = run, %Flow{isolation: :exclusive} = _flow) do
    case Repo.one(from j in NodeJob, where: j.run_id == ^run.id, order_by: [desc: j.id], limit: 1) do
      %NodeJob{state: state, executor_name: name} when state != :revoked and is_binary(name) ->
        check_executor_live(run, name)

      _unpinned ->
        :ok
    end
  end

  defp check_retry_executor(_run, _flow), do: :ok

  defp check_executor_live(run, name) do
    board_id = board_id_of(run)

    case Repo.get_by(Executor, board_id: board_id, name: name) do
      nil -> {:error, {:executor_unavailable, name}}
      executor -> if executor_stale?(executor, now()), do: {:error, {:executor_unavailable, name}}, else: :ok
    end
  end

  defp revive_run(run, node, mode, actor) do
    result =
      try do
        # From-state is the run's OWN current status, not a hardcoded :failed: `restartable?/1`
        # (checked by `check_retryable/1` above) also revives an escalation park — a :parked run
        # `park_kind/1` classifies :escalation (A4: a node failure routed to a human, not a
        # question asked of one) — and both {:failed, :running} and {:parked, :running} are legal
        # edges, so guarding on the run's actual status covers either origin exactly.
        Transitions.transition(run, [run.status], :running,
          set: [
            parked_reason: nil,
            current_node: node,
            failure_detail: nil,
            finished_at: nil,
            retries: run.retries + 1,
            resume_refused_since: nil,
            resume_refused_reason: nil
          ]
        )
      rescue
        e in Ecto.ConstraintError ->
          # The residual window (another active run appears on the card between
          # check_no_active_run/1 and this UPDATE) surfaces the same mapped error a human reads.
          if e.constraint == "runs_one_active_per_card_index",
            do: {:error, :active_run_exists},
            else: reraise(e, __STACKTRACE__)
      end

    case result do
      {:ok, run} ->
        clear_card_block(run, actor)
        broadcast_runs(board_id_of(run), {:run_resumed, run})
        {:ok, _pid} = ensure_server(run, mode)
        {:ok, run}

      # A concurrent transition flipped this run out of :failed under us — a from-state guard
      # the old changeset path lacked. check_retryable/1 + check_no_active_run/1 mean the only
      # realistic cause is another active run now existing on the card, so preserve the code a
      # caller already handles.
      {:error, :not_in_expected_state} ->
        {:error, :active_run_exists}

      {:error, :active_run_exists} = err ->
        err
    end
  end

  # RE253 — retry must leave the card agreeing with the run. A `:failed` card stops reading failed
  # (RLY-189); an escalation-parked `:needs_input` card must ALSO unblock, or the board shows a
  # blocked card asking a question while its run is already live again. This two-element list is
  # an ad-hoc "card state retry has to clear" predicate, NOT a domain partition — do not replace
  # it with a Card status vocabulary function. Genuine questions and `:executor_gone` parks never
  # reach here: `check_retryable/1` refuses them.
  defp clear_card_block(%Run{card_id: card_id}, actor) do
    card = Repo.get!(Card, card_id)
    if card.status in [:failed, :needs_input], do: {:ok, _card} = Cards.clear_failure(card, actor)
    :ok
  end

  @doc "The machine token for a `retry_run/2` refusal — what tests and the API's `error.code` match on."
  def retry_refusal_code({:not_failed, _status}), do: "not_failed"
  def retry_refusal_code(:active_run_exists), do: "active_run_exists"
  def retry_refusal_code(:no_flow), do: "no_flow"
  def retry_refusal_code({:unknown_node, _key}), do: "unknown_node"
  def retry_refusal_code({:executor_unavailable, _name}), do: "executor_unavailable"
  def retry_refusal_code(:awaiting_answer), do: "awaiting_answer"

  @doc """
  The human sentence for a `retry_run/2` refusal — what a person reads when
  retry says no, so each one names the specific thing that blocked it.
  """
  def retry_refusal_message({:not_failed, status}) do
    "This run is #{status}, not failed — only a failed run can be retried."
  end

  def retry_refusal_message(:active_run_exists) do
    "This card already has an active run. Let it finish, or cancel it, before retrying."
  end

  def retry_refusal_message(:no_flow) do
    "This run's flow no longer exists, so there is no node to re-enter."
  end

  def retry_refusal_message({:unknown_node, "(none)"}) do
    "This run has no recorded node executions, so there is no node to retry."
  end

  def retry_refusal_message({:unknown_node, key}) do
    "`#{key}` is not a node in this run's flow."
  end

  def retry_refusal_message({:executor_unavailable, name}) do
    "This run is pinned to executor `#{name}`, which is not connected. Its worktree is " <>
      "unreachable, so the retry would queue a job nothing can claim."
  end

  def retry_refusal_message(:awaiting_answer) do
    "This run is waiting on a human answer, not stalled — answer it instead of restarting."
  end

  @doc """
  The most recent run of `card`, whatever its status — the resolution behind
  `POST /api/cards/:ref/retry`. Deliberately NOT "the most recent FAILED run":
  handing `retry_run/2` the newest run is what lets it refuse a running one by
  name (`{:not_failed, :running}`) instead of 404-ing as though the card had
  never run.
  """
  def latest_run_for_retry(%Card{id: card_id}) do
    Repo.one(from r in Run, where: r.card_id == ^card_id, order_by: [desc: r.id], limit: 1)
  end

  @doc """
  Revive every restartable run on `board` whose card is not already in a terminal-type stage
  — the mass-outage recovery (RLY-228). Each run is revived through the per-run `retry_run/2`
  path, so its own guards (`check_no_active_run`, executor liveness) still apply; a run that
  can't revive is counted `refused`, never fatal. Returns `%{restarted: n, refused: m}` so the
  caller can flash "Restarted N cards."
  """
  def restart_stalled(%Board{} = board, actor) do
    board
    |> restartable_runs()
    |> Enum.reduce(%{restarted: 0, refused: 0}, fn run, acc ->
      case retry_run(run, actor: actor) do
        {:ok, _run} -> %{acc | restarted: acc.restarted + 1}
        {:error, _reason} -> %{acc | refused: acc.refused + 1}
      end
    end)
  end

  @doc "How many runs on `board` are `restartable?/1`, excluding cards already in a terminal-type stage — the board-header badge count (RLY-228)."
  def restartable_count(%Board{} = board), do: board |> restartable_runs() |> length()

  @doc """
  The board's stalled cards, as the restart dialog renders them (RE247): one entry per
  restartable run, carrying the card (with its stage preloaded) and a human reason string.
  Exactly the `restartable_runs/1` set the header badge counts and `restart_stalled/2`
  sweeps, so the dialog can never name a different set than the badge claims. Sorted by
  `ref_number` so the list order is stable across refreshes and restarts.
  """
  def stalled_cards(%Board{} = board) do
    board
    |> restartable_runs()
    |> Enum.map(&%{card: &1.card, run: &1, reason: stall_reason(&1)})
    |> Enum.sort_by(& &1.card.ref_number)
  end

  @doc """
  The one-line reason `run` is stalled — the restart dialog's copy, owned by ONE function the
  way `retry_refusal_message/1` owns retry's (RE247). `restartable?/1` admits exactly two
  states, so there are exactly two sentences.

  The two states are a clean `:failed` run and an ESCALATION park (`park_kind/1 == :escalation`
  — a node failed and the flow's `--on failed --> needs_input` edge handed the card to a human,
  RLY-194/A4). Nothing has died in either: the one state where an agent genuinely vanished is a
  `:executor_gone` park, and `restartable?/1` excludes it. The escalation wording therefore
  echoes the card drawer's copy for the same state (`panel_label(:escalation)` /
  "<node> failed after N attempts — the flow handed this card to you", RE253) so the board
  names one state one way — keep the two in step if either changes.

  The node is `current_node` when the run still has one (an escalation park keeps it), else the
  `node_key` of the run's most recent NodeExecution — `close_run!/3` nils `current_node` on
  every terminal close, so a clean `:failed` run would otherwise name no node at all. This is
  the same recovery `retry_run/2` uses to pick its re-entry node. A run with no execution at
  all reads without the dangling node clause.

  Raises `FunctionClauseError` for any run `restartable?/1` rejects — this describes stalled
  cards only, and a caller reaching it with anything else has a bug worth surfacing loudly
  rather than papering over with a generic sentence.
  """
  def stall_reason(%Run{} = run), do: stall_sentence(run, run.current_node || last_executed_node(run))

  defp stall_sentence(%Run{status: :failed}, nil), do: "Failed"
  defp stall_sentence(%Run{status: :failed}, node), do: "Failed at #{node}"
  defp stall_sentence(%Run{status: :parked, parked_reason: :needs_input}, nil), do: "Node failed — your call"
  defp stall_sentence(%Run{status: :parked, parked_reason: :needs_input}, node), do: "#{node} failed — your call"

  # The board's restartable runs: the LATEST run per card (the same latest-run-per-card model as
  # run_summaries_for_board/1, so the sweep never revives a superseded run), filtered by the one
  # eligibility rule. It is NOT the same SET: run_summaries_for_board/1 has no terminal-stage
  # filter, so a Done-stage card with a failed run still shows a stalled face while being
  # invisible to this query. Cards in a terminal-type stage (`Stage.terminal_types/0`) are
  # excluded HERE, in the single query the header badge, the restart dialog (`stalled_cards/1`),
  # and `restart_stalled/2` all share — a finished card is not stalled, and filtering it out in
  # any second place would let the three disagree (RE247). Latest node-execution outcome per run
  # is read in ONE grouped query, not per-run — the bulk analog of latest_execution_outcome/1.
  defp restartable_runs(%Board{id: board_id}) do
    latest_runs =
      Repo.all(
        from r in Run,
          join: c in Card,
          on: c.id == r.card_id,
          join: s in Stage,
          on: s.id == c.stage_id,
          where: c.board_id == ^board_id and s.type not in ^Stage.terminal_types(),
          distinct: r.card_id,
          order_by: [asc: r.card_id, desc: r.inserted_at, desc: r.id],
          preload: [card: :stage]
      )

    outcomes = latest_outcomes(Enum.map(latest_runs, & &1.id))

    Enum.filter(latest_runs, fn run ->
      restartable_by_outcome?(run.status, run.parked_reason, Map.get(outcomes, run.id))
    end)
  end

  # %{run_id => latest NodeExecution.outcome} for the given run ids, one grouped query.
  defp latest_outcomes([]), do: %{}

  defp latest_outcomes(run_ids) do
    latest =
      from e in NodeExecution,
        where: e.run_id in ^run_ids,
        group_by: e.run_id,
        select: %{run_id: e.run_id, max_id: max(e.id)}

    from(e in NodeExecution,
      join: l in subquery(latest),
      on: l.max_id == e.id,
      select: {e.run_id, e.outcome}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc false
  def park_claimed(%Run{} = run) do
    stop_server(run)
    run = Repo.get!(Run, run.id)

    case Transitions.transition(run, [:running], :parked, set: [parked_reason: :claimed, pinned_executor_name: nil]) do
      {:ok, updated} ->
        revoke_active_jobs(updated)
        broadcast_runs(board_id_of(updated), {:run_parked, updated})

      {:error, :not_in_expected_state} ->
        :ok
    end

    :ok
  end

  @doc false
  def resume_all do
    Run
    |> where([r], r.status == :running)
    |> Repo.all()
    |> Enum.each(&ensure_server(&1, {:reenter, nil}))
  end

  # A run points at the live flow row: a deleted flow (nilified FK or a
  # vanished row) makes the next transition fail loudly with no_flow.
  @doc false
  def load_flow(%Run{flow_id: nil}), do: {:error, :no_flow}

  def load_flow(%Run{flow_id: flow_id}) do
    case Repo.get(Flow, flow_id) do
      nil -> {:error, :no_flow}
      flow -> {:ok, flow}
    end
  end

  @doc false
  def foreach_node_key(%Flow{nodes: nodes}) do
    case Enum.find(nodes, &(not is_nil(&1.foreach))) do
      nil -> nil
      node -> node.key
    end
  end

  # "Which task is next" is DERIVED, never persisted: the first sub_task in
  # position order that isn't done. Done-state already lives durably in Postgres,
  # so a crashed-and-resumed run recomputes the same answer with no cursor.
  @doc false
  def next_sub_task_id(%Run{card_id: card_id}) do
    Repo.one(
      from st in SubTask,
        where: st.card_id == ^card_id and st.done == false,
        order_by: [asc: st.position, asc: st.id],
        limit: 1,
        select: st.id
    )
  end

  @doc false
  def remaining_sub_tasks(%Run{card_id: card_id}) do
    Repo.aggregate(from(st in SubTask, where: st.card_id == ^card_id and st.done == false), :count)
  end

  @doc false
  def insert_execution!(%Run{} = run, node_key, visit, attempt, sub_task_id \\ nil) do
    %NodeExecution{
      run_id: run.id,
      node_key: node_key,
      visit: visit,
      attempt: attempt,
      sub_task_id: sub_task_id,
      started_at: now()
    }
    |> NodeExecution.changeset()
    |> Repo.insert!()
  end

  @doc false
  def insert_job!(%Run{} = run, %NodeExecution{} = execution, payload) do
    %NodeJob{
      run_id: run.id,
      node_execution_id: execution.id,
      card_id: run.card_id,
      kind: :node,
      node_key: execution.node_key,
      state: :queued,
      payload: payload,
      executor_name: exclusive_holder(run, payload)
    }
    |> NodeJob.changeset()
    |> Repo.insert!()
  end

  @doc ~S"""
  Inserts one **talk** turn's dispatch row (ADR 0009): `kind: :talk`, no run, no node
  execution, `card_id` set. `executor_name` is the session's pin — nil for the first turn on a
  card, which is what lets ANY executor take it and become the holder. Mirrors
  `exclusive_holder/2`'s pin-on-the-job-row shape exactly, so `claim_next_job/1` needs no Talk
  knowledge.
  """
  def insert_talk_job!(%Card{} = card, payload, executor_name) when is_map(payload) do
    %NodeJob{
      kind: :talk,
      card_id: card.id,
      node_key: "talk",
      state: :queued,
      payload: payload,
      executor_name: executor_name
    }
    |> NodeJob.changeset()
    |> Repo.insert!()
  end

  @doc "The job row with `id`, or nil. The read `Relay.Talk` uses to resolve a turn's job."
  def get_job(id) when is_integer(id), do: Repo.get(NodeJob, id)

  @doc ~S"""
  Withdraws a live **talk** job so the heartbeat's `revoked_among/2` tells its executor to kill
  the running `claude -p` — the Stop button (ADR 0009 §1). Unconditional server-side: a turn
  whose executor is already gone still ends, which is the only thing that stops such a turn.
  Flow jobs have no clause here on purpose: they are revoked through the run lifecycle
  (`revoke_active_jobs/1`), and a second path into `:revoked` is exactly the duplicated-fact
  bug AGENTS.md forbids.
  """
  def revoke_talk_job(%NodeJob{kind: :talk} = job) do
    {n, _} =
      Repo.update_all(
        from(j in NodeJob, where: j.id == ^job.id and j.state in ^NodeJob.active_states()),
        set: [state: :revoked, finished_at: now()]
      )

    if n == 1, do: :ok, else: {:error, :not_active}
  end

  @doc "Finalises a **talk** job once its turn has reported an outcome. Terminal; idempotent-safe (a second call simply matches no active row)."
  def finish_talk_job!(%NodeJob{kind: :talk} = job) do
    Repo.update_all(
      from(j in NodeJob, where: j.id == ^job.id and j.state in ^NodeJob.active_states()),
      set: [state: :done, finished_at: now()]
    )

    Repo.get!(NodeJob, job.id)
  end

  @doc "How many `## Task N:` steps a card's plan declares. Wraps `Relay.Runs.PlanTasks` so the Talk seed line reads the plan through the ONE parser the foreach node uses."
  def plan_task_count(plan), do: plan |> PlanTasks.parse() |> length()

  # Exclusive runs have absolute executor affinity (ADR 0006 §5): the machine that
  # claims a run's first job is persisted as the run's `pinned_executor_name`
  # (`maybe_pin_run/2`), and every later job — the next node after an advance, a
  # needs-input re-entry, or an `executor_gone` resume — is pinned to that same column,
  # so it lands on the machine holding the run's worktree. The first job of a fresh run
  # reads nil (unpinned → any exclusive executor may start it). `park_claimed/1` (human
  # baton) nils the column, so a baton resume re-offers to any free executor with a
  # fresh worktree; `park_for_reclaim/1` (executor_gone) KEEPS it, so the resume returns
  # to the holder. `shared_clean` runs are never pinned. One column, two readers (here
  # and `active_runs/1`) — no second derivation to drift (RLY-199).
  defp exclusive_holder(%Run{id: run_id}, %{"isolation" => "exclusive"}) do
    Repo.one(from r in Run, where: r.id == ^run_id, select: r.pinned_executor_name)
  end

  defp exclusive_holder(_run, _payload), do: nil

  @doc false
  def finalize_job!(%NodeJob{} = job, attrs) do
    outcome = Map.fetch!(attrs, :outcome)
    detail = attrs[:detail]
    signature = if outcome == :failed, do: Engine.failure_signature(detail)

    execution =
      NodeExecution
      |> Repo.get!(job.node_execution_id)
      |> Changeset.change(
        outcome: outcome,
        detail: detail,
        failure_signature: signature,
        git_sha: attrs[:git_sha],
        session_id: attrs[:session_id],
        cost: attrs[:cost],
        finished_at: now()
      )
      |> Repo.update!()

    job |> Changeset.change(state: :done, finished_at: now()) |> Repo.update!()
    execution
  end

  @doc false
  def close_run!(%Run{} = run, status, failure_detail) do
    case Transitions.transition(run, [:running], status,
           set: [
             parked_reason: nil,
             current_node: nil,
             failure_detail: failure_detail,
             finished_at: now()
           ]
         ) do
      {:ok, updated} ->
        updated

      # Defensively impossible (every caller holds a provably-:running run); the guarded
      # UPDATE already logged the no-op, so return the row's current truth.
      {:error, :not_in_expected_state} ->
        Repo.get!(Run, run.id)
    end
  end

  @doc false
  def revoke_active_jobs(%Run{id: run_id}) do
    # `run_id == ^run_id` already excludes talk jobs (always run_id: nil), but the kind clause
    # is explicit per ADR 0009 so the filter survives a future refactor of this query.
    jobs =
      Repo.all(
        from j in NodeJob,
          where: j.run_id == ^run_id and j.state in ^NodeJob.active_states() and j.kind in ^NodeJob.flow_kinds()
      )

    Enum.each(jobs, fn job ->
      revoked = job |> Changeset.change(state: :revoked, finished_at: now()) |> Repo.update!()
      dispatcher().revoke(revoked)
    end)
  end

  # Builds a job payload: the executor's whole contract. Placeholder
  # expansion ({ref}/{branch}/{relay}) stays executor-side per
  # Schemas.Flow.Node; the engine only supplies the vars. `branch` follows
  # today's runner convention: the card's stored branch, else
  # <key>-<n>-<title-slug> (mirrors bin/relay's slug()).
  @doc false
  def build_payload(%Run{} = run, %Flow{} = flow, node_key, opts) do
    card = Repo.get!(Card, run.card_id)
    board = Repo.get!(Board, card.board_id)
    node = Enum.find(flow.nodes, &(&1.key == node_key))

    vars =
      Map.merge(run.context, %{
        "ref" => Cards.ref(board, card),
        "branch" => card.branch || default_branch(board, card),
        "prior_detail" => opts[:prior_detail],
        "findings" => opts[:findings],
        "sub_task" => sub_task_title(opts[:sub_task_id])
      })

    %{
      "run" => node.run,
      "node_type" => Atom.to_string(node.type),
      "agent" => node.agent,
      "isolation" => Atom.to_string(flow.isolation),
      "resume_session" => opts[:resume_session],
      "vars" => vars
    }
  end

  # {sub_task} lets a foreach node's prompt name the exact task it is working
  # instead of saying "the next unchecked one".
  defp sub_task_title(nil), do: nil

  defp sub_task_title(sub_task_id) do
    Repo.one(from st in SubTask, where: st.id == ^sub_task_id, select: st.title)
  end

  @doc false
  def broadcast_runs(board_id, event) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic(board_id), event)
    :ok
  end

  @doc false
  def board_id_of(%Run{card_id: card_id}) do
    Repo.one!(from c in Card, where: c.id == ^card_id, select: c.board_id)
  end

  @doc false
  def dispatcher, do: Instance.current().dispatcher

  @doc false
  def engine_opts do
    config = Application.get_env(:relay, __MODULE__, [])

    [
      breaker_threshold: Keyword.get(config, :breaker_threshold, 3),
      visit_cap: Keyword.get(config, :visit_cap, 20)
    ]
  end

  @doc false
  def engine_opts(%Run{} = run), do: Keyword.put(engine_opts(), :bonus, run.retries)

  # ADR 0009 rule 2: DynamicSupervisor.start_child/2 severs $callers, so the child would have
  # neither a sandbox connection nor a way back to the caller's engine instance. Pass the chain
  # down explicitly; RunServer.init/1 re-seeds it. In production `callers` is `[self()]` and
  # nothing is registered against it, so this changes nothing.
  defp ensure_server(%Run{id: id}, mode) do
    instance = Instance.current()

    spec =
      {RunServer, run_id: id, mode: mode, registry: instance.registry, callers: Instance.callers()}

    case DynamicSupervisor.start_child(instance.run_supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp stop_server(%Run{id: id}) do
    case Registry.lookup(Instance.current().registry, id) do
      [{pid, _value}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp default_branch(%Board{} = board, %Card{} = card) do
    "#{String.downcase(board.key)}-#{card.ref_number}-#{slug(card.title)}"
  end

  defp slug(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    if slug == "", do: "card", else: slug
  end

  defp topic(board_id), do: "board:#{board_id}:runs"

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
