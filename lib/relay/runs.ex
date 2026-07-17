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
    exports: [Supervisor]

  import Ecto.Query

  alias Ecto.Changeset
  alias Relay.Activity
  alias Relay.Cards
  alias Relay.Repo
  alias Relay.Runs.Engine
  alias Relay.Runs.RunServer
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.Stage

  @pubsub Relay.PubSub
  @append_index 1_000_000
  @supported_node_types [:agent, :shell, :gate]
  @outcomes [:succeeded, :failed, :partial, :needs_input]
  @active_job_states [:queued, :claimed, :running]

  ## Reads

  @doc "The run with `id`; raises when absent."
  def get_run!(id), do: Repo.get!(Run, id)

  @doc "The card's single active (running or parked) run, or nil — backed by the partial unique index."
  def active_run(%Card{id: card_id}) do
    Repo.one(from r in Run, where: r.card_id == ^card_id and r.status in [:running, :parked])
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
    Repo.one(from j in NodeJob, where: j.run_id == ^run_id and j.state in ^@active_job_states)
  end

  @doc "Subscribes the calling process to `board_id`'s runs topic (`board:<id>:runs`)."
  def subscribe(board_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(board_id))

  ## Lifecycle

  @doc """
  Starts a run of `flow` for `card` (same board enforced by the pattern
  match). Guards: the flow must be enabled, its graph must use only
  supported node types (`:human`/`:parallel` → `{:error,
  :unsupported_node_type}`; execution of both is card 09), its start edge
  must target a real node, and the card must have no active run (the
  partial unique index backs this against races). Creates the run + first
  execution + queued job in one transaction, moves the card to the flow's
  works-in stage as `:agent` (the snap sets `:working`; the claim rule
  assigns Relay AI on an unowned card), broadcasts, starts a `RunServer`,
  and dispatches. A card already sitting in the works-in stage is NOT
  re-moved (rejection re-entry: a gratuitous append-move would clear the
  CHANGES REQUESTED banner via `move_card`'s rejection-clearing rule).
  `opts[:context]` is a STRING-keyed map (e.g.
  `%{"changes_requested" => note}`) merged into every job payload's vars.
  """
  def start_run(%Card{board_id: board_id} = card, %Flow{board_id: board_id} = flow, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    start_target = Enum.find(flow.edges, &(&1.from == "start")).to

    cond do
      not flow.enabled -> {:error, :flow_disabled}
      Enum.any?(flow.nodes, &(&1.type not in @supported_node_types)) -> {:error, :unsupported_node_type}
      start_target == "done" -> {:error, :empty_flow}
      true -> do_start_run(card, flow, start_target, context)
    end
  end

  defp do_start_run(card, flow, start_target, context) do
    result =
      Repo.transaction(fn ->
        run = insert_run(card, flow, start_target, context)
        execution = insert_execution!(run, start_target, 1, 1)
        job = insert_job!(run, execution, build_payload(run, flow, start_target, []))
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

  def report_outcome(%NodeJob{} = job, %{outcome: outcome} = attrs) when outcome in @outcomes do
    job = Repo.get!(NodeJob, job.id)
    run = Repo.get!(Run, job.run_id)

    if job.state in @active_job_states and run.status == :running do
      {:ok, pid} = ensure_server(run, :attach)
      GenServer.call(pid, {:report_outcome, job.id, attrs}, :infinity)
    else
      {:error, :job_not_active}
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

    if run.status in [:running, :parked] do
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

  ## Seams for the RunServer, the Listener (Task 3), and the boot resumer.
  ## @doc false: internal engine plumbing, not public context API.

  @doc false
  def resume_run(%Run{status: :parked} = run, opts \\ []) do
    run = run |> Changeset.change(status: :running, parked_reason: nil) |> Repo.update!()
    broadcast_runs(board_id_of(run), {:run_resumed, run})
    {:ok, _pid} = ensure_server(run, {:reenter, Keyword.get(opts, :resume_session)})
    {:ok, run}
  end

  @doc false
  def park_claimed(%Run{} = run) do
    stop_server(run)
    run = Repo.get!(Run, run.id)

    if run.status == :running do
      revoke_active_jobs(run)
      run = run |> Changeset.change(status: :parked, parked_reason: :claimed) |> Repo.update!()
      broadcast_runs(board_id_of(run), {:run_parked, run})
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
  def insert_execution!(%Run{} = run, node_key, visit, attempt) do
    %NodeExecution{run_id: run.id, node_key: node_key, visit: visit, attempt: attempt, started_at: now()}
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
      payload: payload
    }
    |> NodeJob.changeset()
    |> Repo.insert!()
  end

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
    jobs = Repo.all(from j in NodeJob, where: j.run_id == ^run_id and j.state in ^@active_job_states)

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
        "findings" => opts[:findings]
      })

    %{
      "run" => node.run,
      "node_type" => Atom.to_string(node.type),
      "isolation" => Atom.to_string(flow.isolation),
      "resume_session" => opts[:resume_session],
      "vars" => vars
    }
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
