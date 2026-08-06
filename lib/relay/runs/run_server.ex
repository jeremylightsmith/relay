defmodule Relay.Runs.RunServer do
  @moduledoc """
  One transient GenServer per `:running` run: serializes the run's
  transitions. Every transition writes run/execution/job rows in ONE
  transaction first, then applies card effects, then broadcasts, then
  dispatches — Postgres is the checkpoint of record, and a crash between
  steps only ever re-dispatches (never loses) a node. The server stops on
  park and on every terminal status; parking never holds a process
  (ADR 0006). Registered by run id in its instance's Registry and started under its instance's
  run `DynamicSupervisor` (`Relay.Runs.Instance`; `Relay.Runs.Registry` / `Relay.Runs.RunSupervisor`
  in production).

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
  `findings`, so a node re-entered after a failure sees why. A `{:retry, node}`
  goes further (RE251): it carries the ORIGINATING findings — what sent the node
  here in the first place — alongside this attempt's failure detail, re-derived
  from execution history rather than read back off the previous attempt's payload
  (which already holds a merged string and would compound on every retry).

  Under a `foreach` node each execution carries the `sub_task_id` of the
  iteration it belongs to. The derived cursor ("the first sub_task not done")
  advances on exactly ONE thing: a `when: :foreach_remaining` edge. A
  `:foreach_exhausted` edge unbinds, entering the head from outside the loop
  resolves the first undone task, and everything else — a review's failure
  loop-back included — inherits, so a re-run lands on the SAME task (RE252).
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
  alias Relay.Runs.Instance
  alias Relay.Runs.Transitions
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.Stage
  alias Schemas.SubTask

  # RE251: the fixed separator between a retry's ORIGIN findings and the latest attempt's failure
  # detail. Labelling the second half is what lets the agent tell the reviewer's words from the
  # commit guard's.
  @retry_marker "\n\n--- The previous attempt failed; its detail follows. The findings above still apply. ---\n\n"

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    registry = Keyword.get(opts, :registry, Instance.default().registry)
    GenServer.start_link(__MODULE__, opts, name: via(registry, run_id))
  end

  # The registry name arrives in `opts` rather than being resolved here: start_link/1 runs in the
  # DynamicSupervisor's process, which has already lost the caller's $callers chain (ADR 0009).
  defp via(registry, run_id), do: {:via, Registry, {registry, run_id}}

  @impl true
  def init(opts) do
    Instance.adopt_callers(opts)
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
      job.state not in NodeJob.active_states() or run.status != :running ->
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
    attrs =
      run
      |> override_no_op_success(flow, job, attrs)
      |> then(&override_missing_writes(run, flow, job, &1))

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

        run =
          case Transitions.transition(run, [:running], :parked, set: [parked_reason: :needs_input]) do
            {:ok, parked} -> parked
            {:error, :not_in_expected_state} -> Repo.get!(Run, run.id)
          end

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

    opts = [findings: retry_findings(run, execution), sub_task_id: execution.sub_task_id]
    job = Runs.insert_job!(run, next, Runs.build_payload(run, flow, node, opts))

    {next, job}
  end

  # `guard` is the `when` of the edge the engine followed. It rides on the decision so
  # binding_for/5 can key off it instead of re-selecting the edge here — a second copy of edge
  # selection would disagree with the engine on the RLY-179 degrade path, where
  # `execution.outcome` is the unrouted outcome and matches no edge at all.
  defp apply_decision({:transition, node, guard}, run, flow, execution) do
    run = run |> Ecto.Changeset.change(current_node: node) |> Repo.update!()
    sub_task_id = binding_for(run, flow, node, guard, execution)
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

  # Which iteration the NEXT execution belongs to. The DERIVED cursor
  # (`Runs.next_sub_task_id/1` = "the first sub_task not done, by position") advances on
  # EXACTLY ONE thing: the flow author's `when: :foreach_remaining` guard. Every other route
  # into the foreach head is not an advance (RE252).
  #
  #   * :foreach_exhausted edge      -> nil; we've left the loop
  #   * :foreach_remaining edge      -> the derived cursor. The loop tail already checked the
  #                                     finished task off inside this same transaction, so
  #                                     next_sub_task_id/1 returns the next one.
  #   * unguarded edge into the head -> INHERIT, falling back to the derived cursor when
  #                                     unbound (first entry from outside the loop, e.g.
  #                                     branch → implement)
  #   * anything else                -> inherit (spec_review/quality_review stay bound)
  #
  # Keying off the TARGET NODE instead was the RE252 bug. `done` is not a private engine
  # cursor — the card drawer's checkbox and `relay check <ref> <id>` both write it — so a
  # failure loop-back that re-derived the cursor jumped to the next task whenever anything
  # else had checked the in-flight one off, and that task's findings reached nothing.
  defp binding_for(run, flow, node, guard, execution) do
    cond do
      guard == :foreach_exhausted -> nil
      guard == :foreach_remaining -> Runs.next_sub_task_id(run)
      node == Runs.foreach_node_key(flow) -> execution.sub_task_id || Runs.next_sub_task_id(run)
      true -> execution.sub_task_id
    end
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

    if node && node.expects_commits && baseline_sha(run, job) == sha do
      Map.merge(attrs, %{outcome: :failed, detail: no_op_detail(job.node_key, sha)})
    else
      attrs
    end
  end

  defp override_no_op_success(_run, _flow, _job, attrs), do: attrs

  # The git_sha of the most recent outcome-bearing execution with a non-nil sha PRECEDING this
  # node's first attempt of this visit — "HEAD before the node was entered", not "HEAD before
  # this attempt" (the just-finalized row is not written yet, and even if it were it carries a
  # nil git_sha until finalize).
  #
  # RE298: the per-VISIT boundary is the load-bearing part. An attempt that commits and then dies
  # before writing its outcome file is recorded :failed carrying the POST-work sha; baselining on
  # that row leaves the retry structurally unable to pass the guard — the work is already
  # committed, so it cannot move HEAD, and the only way to report success is to fabricate a
  # commit. Per-visit, the visit's real commit still counts, while a visit that genuinely
  # committed nothing is still caught. Not same-node across visits: a spec_review between two
  # implements reports the identical sha. Fall back to the unbounded lookup when the boundary
  # can't be resolved — a missing row is not evidence of a lie.
  defp baseline_sha(run, job) do
    latest =
      from e in NodeExecution,
        where: e.run_id == ^run.id and not is_nil(e.git_sha),
        order_by: [desc: e.id],
        limit: 1,
        select: e.git_sha

    query =
      case visit_first_attempt_id(run, job) do
        nil -> latest
        id -> where(latest, [e], e.id < ^id)
      end

    Repo.one(query)
  end

  # The execution row id of attempt 1 of the {node_key, visit} the given job belongs to — the
  # boundary between "before this node was entered" and "this node's own attempts". Two callers
  # need that boundary: the commit guard's baseline above and `origin_findings/2` below.
  defp visit_first_attempt_id(run, job) do
    case Repo.get(NodeExecution, job.node_execution_id) do
      %NodeExecution{node_key: node_key, visit: visit} -> visit_first_attempt_id(run.id, node_key, visit)
      nil -> nil
    end
  end

  defp visit_first_attempt_id(run_id, node_key, visit) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run_id and e.node_key == ^node_key and e.visit == ^visit and e.attempt == 1,
        order_by: [asc: e.id],
        limit: 1,
        select: e.id
    )
  end

  # RE251: what a retry hands forward as `findings` — the ORIGIN (what sent this node here) plus
  # the LATEST failure (why this attempt failed). Handing only the latest forward loses the
  # reviewer's words the moment the commit guard flips a no-op to :failed, so from attempt 2 on
  # each retry drifted further from the real problem. Origin nil => `execution.detail`,
  # byte-identical to before.
  defp retry_findings(run, execution) do
    case origin_findings(run, execution) do
      nil -> execution.detail
      origin -> origin <> @retry_marker <> to_string(execution.detail)
    end
  end

  # The detail of the last outcome-bearing execution PRECEDING the first attempt of this
  # {node_key, visit} — i.e. what sent the node here — when that execution failed. Same rule the
  # transition path applies inline, read back off history.
  #
  # Derived from execution history, NEVER from the previous attempt's job payload: that payload
  # already holds a merged string, so reading it back would compound the origin on every retry.
  # Re-deriving keeps every attempt at exactly one origin plus one latest, and is restart-safe by
  # construction — the same property Relay.Runs.Engine is built on.
  defp origin_findings(run, %NodeExecution{node_key: node_key, visit: visit}) do
    with id when is_integer(id) <- visit_first_attempt_id(run.id, node_key, visit),
         {:failed, detail} <-
           Repo.one(
             from e in NodeExecution,
               where: e.run_id == ^run.id and e.id < ^id and not is_nil(e.outcome),
               order_by: [desc: e.id],
               limit: 1,
               select: {e.outcome, e.detail}
           ) do
      detail
    else
      _other -> nil
    end
  end

  # Human sentence first, machine token in parens — the engine.ex convention. The 7-char
  # short sha matches how a human reads HEAD on the card.
  defp no_op_detail(node_key, sha) do
    short = String.slice(sha, 0, 7)

    "`#{node_key}` reported success but produced no commits — HEAD is still `#{short}`, " <>
      "unchanged from before the node ran. A node that must produce commits and produced " <>
      "none has not done its work. (no_op_success: #{node_key})"
  end

  # RE244: a node that declares `writes` (card fields it must fill) but reported :succeeded with
  # one of them still blank did not do its work — the "empty spec reached Spec:Review" class.
  # Same load-time seam and same rewrite-before-finalize contract as the commit guard above; the
  # commit guard runs first, and because this clause matches only :succeeded, its more specific
  # message survives. `reads` is deliberately NOT checked here: it is advisory / doctor-only,
  # because plenty of legitimate cards carry a title and no description, and a read precondition
  # would fail the Spec flow on every one of them — do not "complete the symmetry". Fail open
  # when the node is not in the flow.
  defp override_missing_writes(run, flow, job, %{outcome: :succeeded} = attrs) do
    node = Enum.find(flow.nodes, &(&1.key == job.node_key))

    case node && node.writes do
      [_ | _] = declared -> demote_if_blank(run, job, declared, attrs)
      _none -> attrs
    end
  end

  defp override_missing_writes(_run, _flow, _job, attrs), do: attrs

  defp demote_if_blank(run, job, declared, attrs) do
    card = Card |> Repo.get!(run.card_id) |> Repo.preload(:sub_tasks)

    case Relay.Cards.blank_contract_fields(card, declared) do
      [] ->
        attrs

      blank ->
        Map.merge(attrs, %{outcome: :failed, detail: missing_writes_detail(job.node_key, blank, declared)})
    end
  end

  # Human sentence first, machine token in parens — the engine.ex convention.
  defp missing_writes_detail(node_key, blank, declared) do
    verb = if length(blank) == 1, do: "is", else: "are"

    "`#{node_key}` reported success but the card's #{backticked(blank)} #{verb} still empty — " <>
      "the node declares it writes #{backticked(declared)}. A node that must fill a card field " <>
      "and left it blank has not done its work. (missing_writes: #{node_key})"
  end

  defp backticked(fields), do: Enum.map_join(fields, ", ", &"`#{&1}`")

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

  # Terminal path shared with the no-flow branches. `Runs.fail_run/3` owns the close + card
  # mark + broadcast (RE297, one definition used by the engine and the reaper alike); the node's
  # own output is what the card should show, so it is passed as the card detail.
  defp fail_effects(run, execution, reason) do
    Runs.fail_run(run, reason, first_present([execution && execution.detail, reason]))
    :ok
  end
end
