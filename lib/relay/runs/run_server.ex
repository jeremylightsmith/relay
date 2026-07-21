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
    * `{:reenter_new_visit, resume_session}` — a human retry aimed at a
      different node (`relay retry --at`, RLY-189): identical, except the
      current node is entered on a FRESH visit at attempt 1, matching what a
      real `{:transition, node}` does.
    * `:attach` — just serialize incoming reports (server was restarted
      or lazily started by `report_outcome/2`).

  Both re-entry modes pass the last failed execution's detail forward as
  `findings`, so a node re-entered after a failure sees why.

  Under a `foreach` node each execution carries the `sub_task_id` of the
  iteration it belongs to: entering the loop head resolves the first undone
  sub_task, a `:foreach_exhausted` edge unbinds, and everything else inherits.
  The loop tail (the node whose outgoing edges carry a `when` guard) checks its
  sub_task off on `succeeded` — the ROW WRITE happens inside the transaction
  (before the remaining count is recomputed and handed to the engine), but,
  like every other card effect here, the `{:card_upserted, ...}` broadcast for
  it is deferred until after commit.
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
  alias Schemas.SubTask

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
    reenter(state, &enter_same_node!(&1, &2, resume_session))
  end

  # RLY-189: a retry re-entering a DIFFERENT node (`relay retry --at`) must start a
  # fresh visit of that node, attempt 1 — exactly like a real {:transition, node}.
  # Re-entering it on its old visit number would corrupt per-visit retry accounting.
  def handle_continue({:reenter_new_visit, resume_session}, state) do
    reenter(state, &enter_new_visit!(&1, &2, resume_session))
  end

  defp reenter(state, enter_fun) do
    run = Repo.get!(Run, state.run_id)

    case Runs.load_flow(run) do
      {:ok, flow} ->
        {:ok, {execution, job}} =
          Repo.transaction(fn ->
            Runs.revoke_active_jobs(run)
            enter_fun.(run, flow)
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
  # run/execution/job rows. Card effects + broadcasts + dispatch happen after
  # commit (Relay.Cards manages its own transactions and pushes) — the sub_task
  # check-off is the one exception to "no card writes in here": its ROW WRITE
  # must land before Engine.decide runs (remaining_sub_tasks reads it on this
  # same connection), so check_off_sub_task/3 writes it directly and returns
  # the checked-off id; the broadcast for that write still waits until after
  # commit, alongside every other card effect below.
  defp apply_outcome(run, flow, job, attrs, state) do
    attrs = override_no_op_success(run, flow, job, attrs)

    {:ok, {decision, execution, next, checked_off_id}} =
      Repo.transaction(fn ->
        execution = Runs.finalize_job!(job, attrs)
        # Order matters: check off, THEN count, THEN route. One place, one ordering,
        # no second source of truth for "how many tasks are left".
        checked_off_id = check_off_sub_task(run, flow, execution)
        history = outcome_history(run)

        opts =
          Runs.engine_opts(run) ++
            [sub_task_id: execution.sub_task_id, foreach_remaining: Runs.remaining_sub_tasks(run)]

        decision = Engine.decide(flow, history, execution, opts)
        {decision, execution, apply_decision(decision, run, flow, execution), checked_off_id}
      end)

    run = Repo.get!(Run, run.id)
    board_id = Runs.board_id_of(run)
    notify_sub_task_checked_off(run, checked_off_id)
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
    next = Runs.insert_execution!(run, node, execution.visit, execution.attempt + 1, execution.sub_task_id)

    job =
      Runs.insert_job!(
        run,
        next,
        Runs.build_payload(run, flow, node, findings: execution.detail, sub_task_id: execution.sub_task_id)
      )

    {next, job}
  end

  defp apply_decision({:transition, node}, run, flow, execution) do
    run = run |> Ecto.Changeset.change(current_node: node) |> Repo.update!()
    sub_task_id = binding_for(run, flow, node, execution)
    next = Runs.insert_execution!(run, node, next_visit(run, node), 1, sub_task_id)

    opts = [
      prior_detail: execution.detail,
      findings: if(execution.outcome == :failed, do: execution.detail),
      sub_task_id: sub_task_id
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

  # A task is checked off ONLY after it passes every review in the loop — the loop
  # tail is the node whose outgoing edges carry a `when` guard. So a checked box on
  # the card means "reviewed", not "attempted" (strictly better than the grep-gate
  # it replaces, where the implementer checked its own box).
  #
  # Writes the row DIRECTLY (not via Relay.Cards.set_sub_task_done/3) so no
  # broadcast fires from inside apply_outcome's transaction — see the comment
  # there and notify_sub_task_checked_off/2 below. Returns the checked-off
  # sub_task id, or nil when nothing was checked off.
  defp check_off_sub_task(run, flow, %NodeExecution{outcome: :succeeded, sub_task_id: id} = execution)
       when is_integer(id) do
    if loop_tail?(flow, execution.node_key) do
      sub_task = Repo.get_by!(SubTask, id: id, card_id: run.card_id)
      {:ok, _updated} = sub_task |> SubTask.changeset(%{done: true}) |> Repo.update()
      id
    end
  end

  defp check_off_sub_task(_run, _flow, _execution), do: nil

  defp loop_tail?(flow, node_key), do: Enum.any?(flow.edges, &(&1.from == node_key and not is_nil(&1.when)))

  # Post-commit half of check_off_sub_task/3: broadcasts the card_upserted for
  # the row already written inside apply_outcome's transaction. Reloads rather
  # than trusting a stale in-memory card, same as every other effect in this file.
  defp notify_sub_task_checked_off(_run, nil), do: :ok

  defp notify_sub_task_checked_off(run, _sub_task_id) do
    card = Repo.get!(Card, run.card_id)
    Relay.Cards.notify_upserted(card)
  end

  # Which iteration the NEXT execution belongs to:
  #   * entering the foreach head        -> resolve the first undone sub_task
  #   * leaving via a :foreach_exhausted -> nil (we're out of the loop)
  #   * anything else                    -> inherit (spec_review/quality_review and
  #                                          retries stay bound to the same task)
  defp binding_for(run, flow, node, execution) do
    cond do
      node == Runs.foreach_node_key(flow) -> Runs.next_sub_task_id(run)
      exits_loop?(flow, execution, node) -> nil
      true -> execution.sub_task_id
    end
  end

  defp exits_loop?(flow, execution, node) do
    Enum.any?(
      flow.edges,
      &(&1.from == execution.node_key and &1.to == node and &1.on == execution.outcome and
          &1.when == :foreach_exhausted)
    )
  end

  # The current node's binding, for a re-entry that starts a fresh attempt of the
  # same visit (boot resume / needs-input answer / hand-back).
  defp current_sub_task_id(run, node_key) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run.id and e.node_key == ^node_key,
        order_by: [desc: e.id],
        limit: 1,
        select: e.sub_task_id
    )
  end

  # Boot/park re-entry: fresh attempt of the current node, same visit.
  defp enter_same_node!(run, flow, resume_session) do
    node = run.current_node
    visit = max_for(run, node, :visit) || 1
    attempt = (max_in_visit(run, node, visit) || 0) + 1
    enter!(run, flow, node, visit, attempt, resume_session)
  end

  # Retry --at re-entry: a fresh visit of the current node, attempt 1.
  defp enter_new_visit!(run, flow, resume_session) do
    node = run.current_node
    enter!(run, flow, node, next_visit(run, node), 1, resume_session)
  end

  # RLY-189: every re-entry carries the last failure forward as `findings`, exactly as
  # apply_decision({:retry, ...}) already does — a node re-entered after a failure must
  # know why, and a plain re-entry used to start blind.
  defp enter!(run, flow, node, visit, attempt, resume_session) do
    sub_task_id = current_sub_task_id(run, node)
    execution = Runs.insert_execution!(run, node, visit, attempt, sub_task_id)

    opts = [
      resume_session: resume_session,
      sub_task_id: sub_task_id,
      findings: last_failure_detail(run)
    ]

    job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, node, opts))
    {execution, job}
  end

  # RLY-194: a node that must produce commits (expects_commits) but reported :succeeded
  # with HEAD unmoved from before it ran did not do its work. Rewrite the outcome to
  # :failed BEFORE finalize_job! — the seam is load-time deliberate: it is the only place
  # with the flow node (expects_commits), the run (baseline sha) and the raw attrs before
  # finalize_job! computes the failure_signature (which it does only for :failed). Fail
  # open on nil: a missing sha on either side is not evidence of a lie.
  defp override_no_op_success(run, flow, job, %{outcome: :succeeded, git_sha: sha} = attrs) when is_binary(sha) do
    node = Enum.find(flow.nodes, &(&1.key == job.node_key))

    if node && node.expects_commits && baseline_sha(run) == sha do
      Map.merge(attrs, %{outcome: :failed, detail: no_op_detail(job.node_key, sha)})
    else
      attrs
    end
  end

  defp override_no_op_success(_run, _flow, _job, attrs), do: attrs

  # The git_sha of this run's most recent prior outcome-bearing execution with a non-nil
  # sha — the faithful proxy for "HEAD before this node ran" (the just-finalized row is
  # not written yet, and even if it were it carries a nil git_sha until finalize). Not
  # same-node: a spec_review between two implements reports the identical sha.
  defp baseline_sha(run) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run.id and not is_nil(e.git_sha),
        order_by: [desc: e.id],
        limit: 1,
        select: e.git_sha
    )
  end

  # Human sentence first, machine token in parens — the engine.ex convention. The 7-char
  # short sha matches how a human reads HEAD on the card.
  defp no_op_detail(node_key, sha) do
    short = String.slice(sha, 0, 7)

    "`#{node_key}` reported success but produced no commits — HEAD is still `#{short}`, " <>
      "unchanged from before the node ran. A node that must produce commits and produced " <>
      "none has not done its work. (no_op_success: #{node_key})"
  end

  # The detail of the run's most recent outcome-bearing execution, but ONLY when it
  # failed: a re-entry after a park-on-question or a success carries no findings.
  defp last_failure_detail(run) do
    last =
      Repo.one(
        from e in NodeExecution,
          where: e.run_id == ^run.id and not is_nil(e.outcome),
          order_by: [desc: e.id],
          limit: 1,
          select: %{outcome: e.outcome, detail: e.detail}
      )

    case last do
      %{outcome: :failed, detail: detail} -> detail
      _other -> nil
    end
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

  # A terminal failure's :failure entry belongs to Relay.Cards.mark_failed/3 — it
  # carries the detail in `meta`, which the diagnosis surfaces read. Logging here
  # too would double it in the timeline (RLY-179).
  defp log_failure_if_final({:fail, _reason}, _run, _execution), do: :ok

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

  # Run failed → flag the card with the node's actual output so a human sees it at
  # once. RLY-179: this is `mark_failed/3`, not `request_input/3` — the run is
  # terminal, so a `:question` would invite an answer that cannot resume anything.
  # The scheduler skips `:failed` cards by rule, so a card whose last run died is
  # never silently re-pulled.
  #
  # Unlike bin/relay's flag() (which wraps the detail in "[auto] stage failed: …
  # a human needs to look" framing), this posts the bare detail.
  defp card_fail_effects(run, execution) do
    card = Repo.get!(Card, run.card_id)
    detail = first_present([execution && execution.detail, run.failure_detail]) || "The agent's run failed."
    {:ok, _card} = Relay.Cards.mark_failed(card, detail, :agent)
    :ok
  end

  # First non-blank string in `candidates`, or nil. "" is truthy in Elixir, so a
  # naive `||` chain would post a blank Comment body and crash request_input's
  # hard match — this is what makes the blank-detail fallback actually reachable.
  defp first_present(candidates), do: Enum.find(candidates, &(is_binary(&1) and String.trim(&1) != ""))

  # Terminal path shared with the no-flow branches: close the run, leave the
  # failure on the card, mark the card :failed, broadcast.
  defp fail_effects(run, execution, reason) do
    run = Runs.close_run!(run, :failed, reason)
    card_fail_effects(run, execution)
    Runs.broadcast_runs(Runs.board_id_of(run), {:run_finished, run})
    :ok
  end
end
