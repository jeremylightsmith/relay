defmodule Relay.Runs.RunServer do
  @moduledoc """
  One transient GenServer per `:running` run: serializes the run's
  transitions. Every transition writes run/execution/job rows in ONE
  transaction first, then applies card effects, then broadcasts, then
  dispatches — Postgres is the checkpoint of record, and a crash between
  steps only ever re-dispatches (never loses) a node. The server stops on
  park and on every terminal status; parking never holds a process
  (ADR 0006). Registered by run id in `Relay.Runs.Registry`; started
  under `Relay.Runs.RunSupervisor`.

  Start modes ({:continue, mode}):
    * `{:dispatch, job_id}` — fresh start: the row set already exists,
      just dispatch (skips a job no longer :queued, e.g. after a restart).
    * `{:reenter, resume_session}` — boot resume, needs-input resume, and
      hand-back: revoke any leftover non-done job (its dispatcher is
      gone), enter the current node as a fresh attempt of the same visit.
      `resume_session` is non-nil only on the needs-input path — the only
      re-entry that resumes an AI session.
    * `:attach` — just serialize incoming reports (server was restarted
      or lazily started by `report_outcome/2`).
  """

  use GenServer, restart: :transient

  import Ecto.Query

  alias Relay.Repo
  alias Relay.Runs
  alias Relay.Runs.Engine
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.Stage

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
  end

  defp via(run_id), do: {:via, Registry, {Relay.Runs.Registry, run_id}}

  @impl true
  def init(opts) do
    {:ok, %{run_id: Keyword.fetch!(opts, :run_id)}, {:continue, Keyword.fetch!(opts, :mode)}}
  end

  @impl true
  def handle_continue(:attach, state), do: {:noreply, state}

  def handle_continue({:dispatch, job_id}, state) do
    job = Repo.get!(NodeJob, job_id)
    if job.state == :queued, do: Runs.dispatcher().dispatch(job)
    {:noreply, state}
  end

  def handle_continue({:reenter, resume_session}, state) do
    run = Repo.get!(Run, state.run_id)

    case Runs.load_flow(run) do
      {:ok, flow} ->
        {:ok, {execution, job}} =
          Repo.transaction(fn ->
            Runs.revoke_active_jobs(run)
            enter_same_node!(run, flow, resume_session)
          end)

        Runs.broadcast_runs(Runs.board_id_of(run), {:node_started, run, execution})
        Runs.dispatcher().dispatch(job)
        {:noreply, state}

      {:error, :no_flow} ->
        fail_effects(run, nil, "no_flow")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:report_outcome, job_id, attrs}, _from, state) do
    job = Repo.get!(NodeJob, job_id)
    run = Repo.get!(Run, state.run_id)

    cond do
      job.state not in [:queued, :claimed, :running] or run.status != :running ->
        {:reply, {:error, :job_not_active}, state}

      match?({:error, :no_flow}, Runs.load_flow(run)) ->
        {:ok, execution} = Repo.transaction(fn -> Runs.finalize_job!(job, attrs) end)
        fail_effects(run, execution, "no_flow")
        {:stop, :normal, {:ok, Repo.get!(Run, run.id)}, state}

      true ->
        {:ok, flow} = Runs.load_flow(run)
        apply_outcome(run, flow, job, attrs, state)
    end
  end

  # One transaction: finalize the reported attempt, decide, write the next
  # run/execution/job rows. Card effects + broadcasts + dispatch happen
  # after commit (Relay.Cards manages its own transactions and pushes).
  defp apply_outcome(run, flow, job, attrs, state) do
    {:ok, {decision, execution, next}} =
      Repo.transaction(fn ->
        execution = Runs.finalize_job!(job, attrs)
        history = outcome_history(run)
        decision = Engine.decide(flow, history, execution, Runs.engine_opts())
        {decision, execution, apply_decision(decision, run, flow, execution)}
      end)

    run = Repo.get!(Run, run.id)
    board_id = Runs.board_id_of(run)
    log_failure_if_final(decision, run, execution)
    Runs.broadcast_runs(board_id, {:node_finished, run, execution})

    case {decision, next} do
      {_continue, {next_execution, next_job}} ->
        Runs.broadcast_runs(board_id, {:node_started, run, next_execution})
        Runs.dispatcher().dispatch(next_job)
        {:reply, {:ok, run}, state}

      {{:park, :needs_input}, nil} ->
        # Card effect BEFORE the run's own parked write (unlike the other
        # terminal branches): the run row still reads :running in Postgres
        # while ensure_card_blocked commits, so a concurrent Listener
        # reconciliation (RLY-132) sees a run it must leave alone rather than
        # a parked/needs_input run paired with a not-yet-blocked card — which
        # it would misread as "the answer already arrived" and resume.
        ensure_card_blocked(run, execution)
        run = run |> Ecto.Changeset.change(status: :parked, parked_reason: :needs_input) |> Repo.update!()
        Runs.broadcast_runs(board_id, {:run_parked, run})
        {:stop, :normal, {:ok, run}, state}

      {{:finish, :done}, nil} ->
        finish_effects(run, flow)
        Runs.broadcast_runs(board_id, {:run_finished, run})
        {:stop, :normal, {:ok, run}, state}

      {{:fail, _reason}, nil} ->
        card_fail_effects(run, execution)
        Runs.broadcast_runs(board_id, {:run_finished, run})
        {:stop, :normal, {:ok, run}, state}
    end
  end

  # Row writes per decision, inside apply_outcome's transaction. Returns
  # {next_execution, next_job} for continuing decisions, nil otherwise.
  defp apply_decision({:retry, node}, run, flow, execution) do
    next = Runs.insert_execution!(run, node, execution.visit, execution.attempt + 1)
    job = Runs.insert_job!(run, next, Runs.build_payload(run, flow, node, findings: execution.detail))
    {next, job}
  end

  defp apply_decision({:transition, node}, run, flow, execution) do
    run = run |> Ecto.Changeset.change(current_node: node) |> Repo.update!()
    next = Runs.insert_execution!(run, node, next_visit(run, node), 1)

    opts = [
      prior_detail: execution.detail,
      findings: if(execution.outcome == :failed, do: execution.detail)
    ]

    job = Runs.insert_job!(run, next, Runs.build_payload(run, flow, node, opts))
    {next, job}
  end

  # The run's own parked write happens AFTER ensure_card_blocked, in
  # apply_outcome's case handling below — not here (see the comment there).
  defp apply_decision({:park, :needs_input}, _run, _flow, _execution), do: nil

  defp apply_decision({:finish, :done}, run, _flow, _execution) do
    Runs.close_run!(run, :done, nil)
    nil
  end

  defp apply_decision({:fail, reason}, run, _flow, _execution) do
    Runs.close_run!(run, :failed, reason)
    nil
  end

  # Boot/park re-entry: fresh attempt of the current node, same visit.
  defp enter_same_node!(run, flow, resume_session) do
    node = run.current_node
    visit = max_for(run, node, :visit) || 1
    attempt = (max_in_visit(run, node, visit) || 0) + 1
    execution = Runs.insert_execution!(run, node, visit, attempt)
    job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, node, resume_session: resume_session))
    {execution, job}
  end

  defp outcome_history(run) do
    Repo.all(
      from e in NodeExecution,
        where: e.run_id == ^run.id and not is_nil(e.outcome),
        order_by: [asc: e.id]
    )
  end

  # Visit numbering counts ALL rows (including abandoned outcome-nil ones)
  # so numbers never collide; only the Engine's caps ignore abandoned rows.
  defp next_visit(run, node_key), do: (max_for(run, node_key, :visit) || 0) + 1

  defp max_for(run, node_key, field) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run.id and e.node_key == ^node_key,
        select: max(field(e, ^field))
    )
  end

  defp max_in_visit(run, node_key, visit) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run.id and e.node_key == ^node_key and e.visit == ^visit,
        select: max(e.attempt)
    )
  end

  # A failed outcome that did NOT retry leaves its detail on the card
  # timeline as a :failure entry (acceptance 2) — both when a failed edge
  # reroutes and when the run fails.
  defp log_failure_if_final(_decision, _run, nil), do: :ok
  defp log_failure_if_final({:retry, _node}, _run, _execution), do: :ok

  defp log_failure_if_final(_decision, run, %NodeExecution{outcome: :failed} = execution) do
    card = Repo.get!(Card, run.card_id)
    {:ok, _entry} = Relay.Activity.log(card, %{type: :failure, actor: :agent, text: execution.detail || "node failed"})
    :ok
  end

  defp log_failure_if_final(_decision, _run, _execution), do: :ok

  # In the real flow the agent has already blocked the card via the
  # needs-input API; ensure it idempotently with the outcome detail as the
  # question fallback. The Listener's resume rule compares against
  # :needs_input, so reconciliation self-heals either ordering.
  defp ensure_card_blocked(run, execution) do
    card = Repo.get!(Card, run.card_id)

    if card.status != :needs_input do
      {:ok, _card} = Relay.Cards.request_input(card, execution.detail || "The agent needs input.", :agent)
    end

    :ok
  end

  # Run closed :done → the card lands on the flow's lands-on stage (the
  # move's snap sets the arrival status, e.g. :in_review at Spec:Review).
  # A disarmed trigger (deleted stage → nil FK) skips the move rather than
  # crashing a finished run.
  defp finish_effects(run, flow) do
    if flow.lands_on_stage_id do
      card = Repo.get!(Card, run.card_id)
      lands_on = Repo.get!(Stage, flow.lands_on_stage_id)
      {:ok, _card} = Relay.Cards.move_card(card, lands_on, 1_000_000, :agent)
    end

    :ok
  end

  # Run failed → flag the card with the node's actual output so a human sees it
  # at once: request_input blocks the card (:needs_input → amber, needs-you
  # rollup) and the scheduler skips :needs_input cards by rule (it must not
  # re-pull a card whose last run failed — a stronger guarantee than the old
  # :ready-in-a-work-stage accident). B1 / RLY-136, parity with bin/relay's flag().
  defp card_fail_effects(run, execution) do
    card = Repo.get!(Card, run.card_id)

    detail =
      Enum.find(
        [execution && execution.detail, run.failure_detail, "The agent's run failed."],
        &(is_binary(&1) and String.trim(&1) != "")
      )

    {:ok, _card} = Relay.Cards.request_input(card, detail, :agent)
    :ok
  end

  # Terminal path shared with the no-flow branches: close the run, leave
  # the failure on the card, flag the card :needs_input, broadcast.
  defp fail_effects(run, execution, reason) do
    run = Runs.close_run!(run, :failed, reason)
    log_failure_if_final({:fail, reason}, run, execution)
    card_fail_effects(run, execution)
    Runs.broadcast_runs(Runs.board_id_of(run), {:run_finished, run})
    :ok
  end
end
