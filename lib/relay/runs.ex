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
  behaviour (`config :relay, :runs_dispatcher`), so the whole engine is
  provable with a fake executor before cards 04/05 exist.
  """

  use Boundary,
    deps: [Relay.Activity, Relay.Boards, Relay.Cards, Relay.Events, Relay.Flows, Relay.Repo, Schemas],
    exports: [Supervisor, Capacity, RunDetail, SchedulerSupervisor]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs.Capacity
  alias Relay.Runs.Engine
  alias Relay.Runs.PlanTasks
  alias Relay.Runs.Preflight
  alias Relay.Runs.RunServer
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.Server, as: SchedulerServer
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

  @doc "The run's single queued/claimed/running job, or nil."
  def active_job(%Run{id: run_id}) do
    Repo.one(from j in NodeJob, where: j.run_id == ^run_id and j.state in ^NodeJob.active_states())
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

  # A live run whose node-job is stuck (queued/unclaimed/held by a silent executor) this long
  # has stopped moving. Well above a legitimate long node's own claimed runtime — a 40-minute
  # plan-implementer node is *running*, not stalled, and stays neutral (see run_stalled?/3).
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
  Run ids whose current node-job is actively `:running` on a non-stale executor at `now`. The
  complement — queued, unclaimed, or held by a silent executor — is what BoardLive treats as a
  candidate for the stalled run-face treatment. Reuses `executor_stale?/2`, so "working" can
  never disagree with what the reclaim sweep would act on.
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
      where: c.board_id == ^board.id and j.state == :running,
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

    if card.status == :ready and active_owner == :ai and not active_run? do
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
        run = insert_run(card, flow, start_target, context)
        sub_task_id = if start_target == foreach_node_key(flow), do: next_sub_task_id(run)
        execution = insert_execution!(run, start_target, 1, 1, sub_task_id)
        job = insert_job!(run, execution, build_payload(run, flow, start_target, sub_task_id: sub_task_id))
        {run, execution, job}
      end)

    case result do
      {:ok, {run, execution, job}} ->
        card =
          if card.stage_id == flow.works_in_stage_id do
            card
          else
            works_in = Repo.get!(Stage, flow.works_in_stage_id)
            {:ok, moved} = Cards.move_card(card, works_in, @append_index, :agent)
            moved
          end

        # The move's snap only overrides an INVALID status (ADR 0003); :ready is
        # already valid on a work stage, so the AI taking over needs an explicit
        # :working set — status changes only ever happen through set_status/3.
        {:ok, _card} = Cards.set_status(card, %{status: :working}, :agent)

        broadcast_runs(card.board_id, {:run_started, run})
        broadcast_runs(card.board_id, {:node_started, run, execution})
        {:ok, _pid} = ensure_server(run, {:dispatch, job.id})
        {:ok, run}

      {:error, %Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :card_id), do: {:error, :active_run_exists}, else: {:error, :invalid}
    end
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
  (serialized per run). Jobs not in queued/claimed/running are rejected
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

  @doc "claimed → running."
  def start_job(%NodeJob{} = job), do: transition_job(job, [:claimed], state: :running)

  defp transition_job(job, from_states, sets) do
    query = from j in NodeJob, where: j.id == ^job.id and j.state in ^from_states, select: j

    case Repo.update_all(query, set: sets) do
      {1, [updated]} -> {:ok, updated}
      {0, _none} -> {:error, :job_not_active}
    end
  end

  @doc """
  Cancels an active run: stops its server, revokes any in-flight job,
  marks the run `:cancelled`, and logs an `:action` entry to the card's
  timeline. The card itself is left where it sits.
  """
  def cancel_run(%Run{} = run) do
    stop_server(run)
    run = Repo.get!(Run, run.id)

    if run.status in Run.active_statuses() do
      revoke_active_jobs(run)
      run = close_run!(run, :cancelled, nil)
      card = Repo.get!(Card, run.card_id)
      {:ok, _entry} = Activity.log(card, %{type: :action, actor: :agent, text: "run cancelled"})
      broadcast_runs(card.board_id, {:run_finished, run})
      {:ok, run}
    else
      {:error, :not_active}
    end
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
  @min_executor_version 19

  @doc "The minimum `bin/relay` EXECUTOR_VERSION this server will claim jobs to."
  def min_executor_version, do: @min_executor_version

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
  def claim_next_job(%Executor{board_id: board_id, name: name, capacity: capacity}) do
    allowed = for {class, n} <- capacity, is_integer(n) and n > 0, do: class
    # Never short-circuit on empty capacity: a job pinned to this executor (an
    # exclusive run it already holds — ADR 0006 §5) is claimable regardless of
    # advertised free capacity, since the executor is already holding that slot.
    Repo.transaction(fn -> do_claim_next_job(board_id, name, allowed) end)
  end

  defp do_claim_next_job(board_id, name, allowed) do
    query =
      from j in NodeJob,
        join: r in Run,
        on: r.id == j.run_id,
        join: c in Card,
        on: c.id == r.card_id,
        where: c.board_id == ^board_id,
        where: j.state == :queued,
        # Unpinned jobs need advertised free capacity in their class; a job
        # already pinned to this executor bypasses the capacity filter.
        where:
          j.executor_name == ^name or
            (is_nil(j.executor_name) and fragment("?->>'isolation'", j.payload) in ^allowed),
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
  # holder rewrites the same name. shared_clean runs are never pinned.
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
        on_board =
          Repo.all(
            from j in NodeJob,
              join: r in Run,
              on: r.id == j.run_id,
              join: c in Card,
              on: c.id == r.card_id,
              where: c.board_id == ^board_id and j.id in ^ids,
              select: {j.id, j.state}
          )

        for {id, state} <- on_board, state not in NodeJob.active_states(), do: id
    end
  end

  def revoked_among(_board, _running), do: []

  @doc """
  The subset of `bound_run_ids` whose run is TERMINAL (`status in Run.terminal_statuses()`) on
  THIS board — the run-scoped analogue of `revoked_among/2`, one level up. The executor reports
  the run-ids of exclusive slots it holds with no live job (`bound_runs`); this names the ones it
  may now release, because the run has ended server-side.

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
            select: r.id
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
  in a raw path param) when it is held by a live claim (`state in [:claimed,
  :running]`). `{:error, :not_found}` when no such job exists on the board or
  `id` isn't a valid integer, `{:error, :conflict}` when it exists but is not
  currently held — so a zombie executor cannot clobber a reassigned or
  revoked job.
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
          where: j.id == ^id and c.board_id == ^board_id
      )

    cond do
      is_nil(job) -> {:error, :not_found}
      job.state in NodeJob.claimed_states() -> {:ok, job}
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

  @doc "The board's raw `Executor` rows — the lean read `Scheduler.Server` builds its snapshot's `executors` map from."
  def list_board_executors(board_id) do
    Repo.all(from e in Executor, where: e.board_id == ^board_id)
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
        {snapshot, _cards_by_id} = SchedulerServer.build_snapshot(board.id, SchedulerServer.configured_engine())
        {reason, bits} = Scheduler.capacity_diagnosis(snapshot)

        if age > @stopped_work_after_s and reason in [:executor_outdated, :no_executor, :executor_gone] do
          %{
            reason: reason,
            detail: stopped_work_detail(reason, bits, age),
            queued_count: count,
            oldest_queued_age_s: age,
            evidence: bits
          }
        end
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

  defp job_working?(%NodeJob{state: :running, executor_name: name}, board, now) when is_binary(name) do
    case Repo.get_by(Executor, board_id: board.id, name: name) do
      nil -> false
      executor -> not executor_stale?(executor, now)
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
  # can never disagree with what the reclaim sweep would act on. A `:running` job is
  # excluded: the executor is demonstrably alive enough to have started it, and the
  # heartbeat's staleness is what the reclaim sweep is for.
  defp stranded?(nil, _board, _now), do: false
  defp stranded?(%NodeJob{state: :running}, _board, _now), do: false

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

  # Every active job on this board that some executor is holding, grouped by `executor_name`.
  # Same join shape as reclaim_executor/1 — NodeJob → Run → Card — scoped by board so one
  # executor name shared across boards never leaks work sideways.
  defp active_jobs_by_executor(%Board{} = board) do
    from(j in NodeJob,
      join: r in Run,
      on: r.id == j.run_id,
      join: c in Card,
      on: c.id == r.card_id,
      where: c.board_id == ^board.id,
      where: j.state in ^NodeJob.active_states(),
      where: not is_nil(j.executor_name),
      order_by: [asc: j.claimed_at, asc: j.id],
      select: %{
        executor_name: j.executor_name,
        job_id: j.id,
        ref_number: c.ref_number,
        title: c.title,
        node_key: j.node_key,
        state: j.state,
        isolation: fragment("?->>'isolation'", j.payload),
        claimed_at: j.claimed_at
      }
    )
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
  # :claimed/:running under a dead executor's name, even if the run itself
  # already moved on (e.g. parked/finished via a concurrent path) by the time
  # this runs — then, only for a still-:running run, flips it to
  # :parked/:executor_gone (affinity is absolute; the run waits for its
  # machine).
  def park_for_reclaim(%Run{} = run) do
    stop_server(run)
    run = Repo.get!(Run, run.id)

    revoke_active_jobs(run)

    query = from r in Run, where: r.id == ^run.id and r.status == :running, select: r

    case Repo.update_all(query, set: [status: :parked, parked_reason: :executor_gone]) do
      {1, [updated]} -> broadcast_runs(board_id_of(updated), {:run_parked, updated})
      {0, _none} -> :ok
    end

    :ok
  end

  ## Seams for the RunServer, the Listener (Task 3), and the boot resumer.
  ## @doc false: internal engine plumbing, not public context API.

  @doc false
  def resume_run(%Run{id: id} = _run, opts \\ []) do
    query = from r in Run, where: r.id == ^id and r.status == :parked, select: r

    case Repo.update_all(query, set: [status: :running, parked_reason: nil]) do
      {1, [updated]} ->
        broadcast_runs(board_id_of(updated), {:run_resumed, updated})
        {:ok, _pid} = ensure_server(updated, {:reenter, Keyword.get(opts, :resume_session)})
        {:ok, updated}

      {0, _none} ->
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

  defp check_retryable(%Run{status: :failed}), do: :ok
  defp check_retryable(%Run{status: status}), do: {:error, {:not_failed, status}}

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
    changeset =
      run
      |> Changeset.change(
        status: :running,
        parked_reason: nil,
        current_node: node,
        failure_detail: nil,
        finished_at: nil,
        retries: run.retries + 1
      )
      |> Run.changeset()

    case Repo.update(changeset) do
      {:ok, run} ->
        clear_card_failure(run, actor)
        broadcast_runs(board_id_of(run), {:run_resumed, run})
        {:ok, _pid} = ensure_server(run, mode)
        {:ok, run}

      {:error, %Changeset{}} ->
        {:error, :active_run_exists}
    end
  end

  # RLY-179 marks the card :failed when a run dies, and the scheduler skips :failed
  # cards — so a retry that left the card alone would put the board in permanent
  # disagreement with a live run.
  defp clear_card_failure(%Run{card_id: card_id}, actor) do
    card = Repo.get!(Card, card_id)
    if card.status == :failed, do: {:ok, _card} = Cards.clear_failure(card, actor)
    :ok
  end

  @doc "The machine token for a `retry_run/2` refusal — what tests and the API's `error.code` match on."
  def retry_refusal_code({:not_failed, _status}), do: "not_failed"
  def retry_refusal_code(:active_run_exists), do: "active_run_exists"
  def retry_refusal_code(:no_flow), do: "no_flow"
  def retry_refusal_code({:unknown_node, _key}), do: "unknown_node"
  def retry_refusal_code({:executor_unavailable, _name}), do: "executor_unavailable"

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

  @doc false
  def park_claimed(%Run{} = run) do
    stop_server(run)
    run = Repo.get!(Run, run.id)

    query = from r in Run, where: r.id == ^run.id and r.status == :running, select: r

    case Repo.update_all(query, set: [status: :parked, parked_reason: :claimed, pinned_executor_name: nil]) do
      {1, [updated]} ->
        revoke_active_jobs(updated)
        broadcast_runs(board_id_of(updated), {:run_parked, updated})

      {0, _none} ->
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
      node_key: execution.node_key,
      state: :queued,
      payload: payload,
      executor_name: exclusive_holder(run, payload)
    }
    |> NodeJob.changeset()
    |> Repo.insert!()
  end

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
    run
    |> Changeset.change(
      status: status,
      parked_reason: nil,
      current_node: nil,
      failure_detail: failure_detail,
      finished_at: now()
    )
    |> Repo.update!()
  end

  @doc false
  def revoke_active_jobs(%Run{id: run_id}) do
    jobs = Repo.all(from j in NodeJob, where: j.run_id == ^run_id and j.state in ^NodeJob.active_states())

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
  def dispatcher, do: Application.get_env(:relay, :runs_dispatcher, Relay.Runs.NoopDispatcher)

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

  defp ensure_server(%Run{id: id}, mode) do
    case DynamicSupervisor.start_child(Relay.Runs.RunSupervisor, {RunServer, run_id: id, mode: mode}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp stop_server(%Run{id: id}) do
    case Registry.lookup(Relay.Runs.Registry, id) do
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
