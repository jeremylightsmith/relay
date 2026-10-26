defmodule Hamaca.Runs.RunServer do
  @moduledoc """
  One transient GenServer per `:running` run: serializes the run's
  transitions. Every transition writes run/execution/job rows in ONE
  transaction first, then applies card effects, then broadcasts, then
  dispatches — Postgres is the checkpoint of record, and a crash between
  steps only ever re-dispatches (never loses) a node. The server stops on
  park and on every terminal status; parking never holds a process
  (ADR 0006). Registered by run id in its instance's Registry and started under its instance's
  run `DynamicSupervisor` (`Hamaca.Runs.Instance`; `Hamaca.Runs.Registry` / `Hamaca.Runs.RunSupervisor`
  in production).

  Start modes ({:continue, mode}):
    * `{:dispatch, job_ids}` — fresh start: the row set already exists,
      just dispatch every listed job (skipping one no longer :queued, e.g. after
      a restart). A start edge into a `fan_out` lists one job per started branch.
    * `{:reenter, resume_session}` — boot resume of a run with **no** active
      job, needs-input resume, and hand-back: revoke any leftover non-done job (its dispatcher is
      gone), enter the current node as a fresh attempt of the same visit.
      `resume_session` is non-nil only on the needs-input path — the only
      re-entry that resumes an AI session.
      Capped (RE410): when the current node's visit already ends in
      `Hamaca.Runs.max_outcomeless_reentries/0` outcome-nil attempts, it
      revokes the job, stamps the newest of them `:needs_input` and parks the
      run instead of entering another attempt.
    * `{:reenter_new_visit, resume_session}` — a human retry aimed at a
      different node (`relay retry --at`, RLY-189): identical, except the
      current node is entered on a FRESH visit at attempt 1, matching what a
      real `{:transition, node}` does.
    * `{:advance_foreach, resume_session}` — a human advancing a foreach past a task
      whose work is already committed (`Runs.advance_foreach/2`, RE310): like
      `{:reenter_new_visit, _}`, except the sub_task binding is RE-DERIVED from the
      (now checked-off) cursor instead of inherited.
    * `:attach` — just serialize incoming reports (server was restarted
      or lazily started by `report_outcome/2`). Also how boot resume adopts a
      run whose `queued`/`claimed` job survived the restart (RE410,
      `Hamaca.Runs.boot_mode/1`): no revoke, no dispatch.

  Steered re-entry (RE358 Steer now) is a call, not a start mode: `{:steer, actor, body,
  image_ids}` saves the `:steer` comment first, then — when the run is on an agent node with an
  outcome-less active attempt — stamps that attempt `:steered`, revokes its job and enters the
  SAME node as the next attempt of the same visit, resuming the stopped attempt's `session_id` and
  carrying its job's `findings` / `prior_detail` forward. One transaction, then `:node_finished` +
  `:node_started` and dispatch. It is not capped by RE410 (the `:steered` stamp ends the
  outcome-less streak), and the run's status is never written. Otherwise the steer is a note.

  `init/1` refuses (`:ignore`) a run that is missing or no longer `:running` (RE412), so no
  start mode ever runs for a run that a concurrent close or park already took over. The one
  exception (RE437) is `:attach` on a run parked on `:needs_input` whose open region still has a
  `:running` branch (`Hamaca.Runs.attachable_while_parked?/1`): those siblings keep reporting.

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

  ## Fan-out regions (RE437)

  A `fan_out` / `fan_in` pair (`Schemas.Flow.regions/1`) is resolved here, never by a runner: a
  control node is a `node_executions` row with an immediate outcome and no job.

    * **Entering** a region (a `{:transition, fan_out, _}`, or a start edge into one via
      `enter_region!/4`) sets `run.current_node` to the `fan_out` — where it stays while the
      region is open — records the `fan_out` `:succeeded`, inserts one `Schemas.RunBranch` row
      per branch (`:queued`) and starts the first `max_parallel` of them by position.
    * **Starting** a branch sets its row `:running` and enqueues the branch's first node with
      `run_branch_id` set. Its `prior_detail` / `findings` are re-derived from history — the last
      outcome-bearing non-branch execution before the `fan_out` — so a branch started later from
      the queue gets the same vars as its siblings.
    * **Inside** a branch, `Engine.decide/4` sees only that branch's history, so retries, loop
      budgets, the visit cap and the breaker all count per branch. A transition to another branch
      node stays in the branch; one to the `fan_in` ends the branch with the node's outcome; a
      `{:fail, _}` ends the branch `:failed` (one `:failure` timeline entry) without failing the
      run. Each ended branch frees a slot for the next `:queued` one.
    * **Joining** happens when every row is `:ended`: the `fan_in` is recorded with
      `Engine.join/1`'s labelled result, checked off as a loop tail when it carries foreach
      guards, then decided and routed like any other execution.
    * **Parking** a branch (a question, an escalation edge, a `:blocked`) sets its row `:parked` and
      parks the run, revoking no sibling job. While the run is parked a sibling's report
      (`Hamaca.Runs.report_accepted?/2`) is decided and routed inside its branch as usual, but no
      queued branch starts and no join happens — and the server stops after each such report, so a
      parked run never holds a process.
    * **Re-entering** with a region open — every start mode that re-enters — goes branch by branch:
      a `:running` row that kept its job is left alone, one that lost it and every `:parked` row
      get a fresh attempt of the same visit (a parked one resuming its own `:needs_input`
      session), jobs are revoked per row, then the region is scheduled. The RE410 outcome-less cap
      counts per branch and parks that branch. With no region open, re-entering at a `fan_out`, a
      branch node or a `fan_in` opens a fresh region at the `fan_out`.

  A `{:requeue, node}` (RE267) is a usage-limit wait: the node's agent was refused by a Claude
  usage limit whose reset the runner knows. It continues like a retry — attempt +1, same visit and
  binding — but the new job's payload is a verbatim copy of the blocked job's, because the node
  never ran, and the card gets one `:action` timeline line saying when the limit resets.
  """

  use GenServer, restart: :transient

  import Ecto.Query

  alias Hamaca.Flows
  alias Hamaca.Repo
  alias Hamaca.Runs
  alias Hamaca.Runs.Engine
  alias Hamaca.Runs.Instance
  alias Hamaca.Runs.Transitions
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run
  alias Schemas.RunBranch
  alias Schemas.SubTask

  # RE251: the fixed separator between a retry's ORIGIN findings and the latest attempt's failure
  # detail. Labelling the second half is what lets the agent tell the reviewer's words from the
  # commit guard's.
  @retry_marker "\n\n--- The previous attempt failed; its detail follows. The findings above still apply. ---\n\n"

  # RE437: why a queued branch ended without running — the live flow no longer has it.
  @branch_removed "branch removed from the flow"
  @region_removed "fan-out region removed from the flow"

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
    # First: the re-seeded `$callers` chain is what gives this process its DB connection.
    Instance.adopt_callers(opts)
    run_id = Keyword.fetch!(opts, :run_id)

    mode = Keyword.fetch!(opts, :mode)

    # RE412: a run that went terminal or parked before its server came up has nothing to
    # serialize — `:ignore` lets `Runs.ensure_server/2` report `{:error, :run_not_running}`.
    # RE437: the one exception is a run parked while its region still has a `:running` branch,
    # and only to attach — those siblings' reports still need serializing.
    case Repo.get(Run, run_id) do
      %Run{status: :running} -> {:ok, %{run_id: run_id}, {:continue, mode}}
      %Run{status: :parked} = run when mode == :attach -> attach_parked(run)
      _gone_or_not_running -> :ignore
    end
  end

  defp attach_parked(run) do
    if Runs.attachable_while_parked?(run), do: {:ok, %{run_id: run.id}, {:continue, :attach}}, else: :ignore
  end

  @impl true
  def handle_continue(:attach, state), do: {:noreply, state}

  def handle_continue({:dispatch, job_ids}, state) when is_list(job_ids) do
    for job_id <- job_ids, job = Repo.get!(NodeJob, job_id), job.state == :queued, do: dispatch_job(job)
    {:noreply, state}
  end

  # RE410: the only re-entry that continues an existing visit, so the only one with an
  # outcome-less streak to cap.
  def handle_continue({:reenter, resume_session}, state) do
    reenter(state, &enter_same_node!(&1, &2, resume_session), cap_outcomeless: true, binding: :inherit)
  end

  # RLY-189: a retry re-entering a DIFFERENT node (`relay retry --at`) must start a
  # fresh visit of that node, attempt 1 — exactly like a real {:transition, node}.
  # Re-entering it on its old visit number would corrupt per-visit retry accounting.
  def handle_continue({:reenter_new_visit, resume_session}, state) do
    reenter(state, &enter_new_visit!(&1, &2, resume_session, :inherit), binding: :inherit)
  end

  # RE310: the human "this task is already done, continue" hatch (`Runs.advance_foreach/2`). A
  # fresh visit of the foreach head like {:reenter_new_visit, _}, except the binding is RE-DERIVED
  # rather than inherited — advance_foreach/2 has just checked the stale task off, so the derived
  # cursor is the NEXT one. This is the only caller allowed to re-derive it; every other re-entry
  # inherits, which is what keeps a review-failed loop-back on the SAME task (RE252).
  def handle_continue({:advance_foreach, resume_session}, state) do
    reenter(state, &enter_new_visit!(&1, &2, resume_session, :rebind), binding: :rebind)
  end

  # Every re-entry mode lands here. The rows are written in one transaction as `effects`, then
  # settled exactly like an outcome's (broadcast, dispatch, park). `opts[:binding]` is the mode's
  # binding rule for a region re-opened at a control node; `opts[:cap_outcomeless]` caps the
  # whole-run same-node path (RE410).
  defp reenter(state, enter_fun, opts) do
    run = Repo.get!(Run, state.run_id)

    case Runs.load_flow(run) do
      {:ok, flow} ->
        {:ok, effects} = Repo.transaction(fn -> reentry_effects!(run, flow, enter_fun, opts) end)

        case settle(run, flow, effects, nil) do
          {:continue, _reply} -> {:noreply, state}
          {:stop, _reply} -> {:stop, :normal, state}
        end

      {:error, :no_flow} ->
        fail_effects(run, nil, "no_flow")
        {:stop, :normal, state}
    end
  end

  # RE437: an open region re-enters branch by branch, whatever the mode — the mode's node and its
  # resume_session describe a whole-run position the region has replaced. With no open region, a
  # current node that is a control node or inside a region re-opens that region afresh.
  defp reentry_effects!(run, flow, enter_fun, opts) do
    case Runs.open_region(run) do
      [_ | _] = rows ->
        reenter_region!(run, flow, rows)

      [] ->
        if region_node?(flow, run.current_node),
          do: reopen_region!(run, flow, Keyword.fetch!(opts, :binding)),
          else: reenter_rows!(run, flow, enter_fun, opts)
    end
  end

  # Inside reenter/3's transaction: revoke the leftover job, then either enter a fresh attempt
  # or — on the capped same-node path, at the cap — stamp the park instead (RE410).
  defp reenter_rows!(run, flow, enter_fun, opts) do
    # Counted BEFORE the revoke, so the attempt being abandoned right now is included.
    streak =
      if Keyword.get(opts, :cap_outcomeless, false), do: outcomeless_streak(run, run.current_node, nil), else: []

    Runs.revoke_active_jobs(run)

    if length(streak) >= Runs.max_outcomeless_reentries() do
      park_on(new_effects(), stamp_outcomeless_park!(hd(streak)))
    else
      {execution, job} = enter_fun.(run, flow)
      add_started(new_effects(), execution, job)
    end
  end

  defp region_node?(flow, node), do: Flow.fan_out?(flow, node) or not is_nil(Flow.enclosing_region(flow, node))

  # A control node or a node inside a region, with no region open (a retry, an advance, a resume
  # parked on the fan_out): open a fresh region — a new fan_out visit with fresh rows, exactly as
  # a transition into the fan_out does. No branch is live, so the whole-run revoke is safe here.
  defp reopen_region!(run, flow, binding) do
    fan_out =
      if Flow.fan_out?(flow, run.current_node),
        do: run.current_node,
        else: Flow.enclosing_region(flow, run.current_node).fan_out

    Runs.revoke_active_jobs(run)
    open_region!(new_effects(), run, flow, fan_out, reentry_binding(run, fan_out, binding))
  end

  # The region-aware re-entry (RE437): each row in position order — a `:running` branch keeping
  # its job is left alone; one that lost its job (a restart, a hand-back, a lost runner) and every
  # `:parked` one get a fresh attempt of the same visit; `:queued` waits for scheduling. Then the
  # region is scheduled as after any branch event. Jobs are revoked per row, never run-wide.
  defp reenter_region!(run, flow, rows) do
    fo = Repo.get!(NodeExecution, hd(rows).fan_out_execution_id)
    live = live_jobs_by_branch(run)

    rows
    |> Enum.reduce(new_effects(), &reenter_branch!(&2, run, flow, fo, &1, Map.get(live, &1.id, [])))
    |> fill_region(run, flow, fo)
  end

  defp reenter_branch!(effects, _run, _flow, _fo, %RunBranch{state: :running}, [_ | _]), do: effects

  # RE410 per branch: at the cap the branch parks — and with it the run — instead of looping.
  defp reenter_branch!(effects, run, flow, fo, %RunBranch{state: :running} = row, []) do
    streak = outcomeless_streak(run, row.current_node, row.id)

    if length(streak) >= Runs.max_outcomeless_reentries() do
      park_row!(row)
      park_on(effects, stamp_outcomeless_park!(hd(streak)))
    else
      enter_branch!(effects, run, flow, fo, row, nil)
    end
  end

  defp reenter_branch!(effects, run, flow, fo, %RunBranch{state: :parked} = row, jobs) do
    Enum.each(jobs, &Runs.revoke_job!/1)
    row = row |> Ecto.Changeset.change(state: :running) |> Repo.update!()
    enter_branch!(effects, run, flow, fo, row, branch_resume_session(row))
  end

  defp reenter_branch!(effects, _run, _flow, _fo, _queued_or_ended, _jobs), do: effects

  # A fresh attempt of the branch's current node, same visit — enter_same_node!/3 for one branch.
  defp enter_branch!(effects, run, flow, fo, row, resume_session) do
    node = row.current_node
    {visit, attempt} = same_visit_attempt(run, node)
    execution = Runs.insert_execution!(run, node, visit, attempt, fo.sub_task_id, row.id)

    opts = [
      resume_session: resume_session,
      sub_task_id: fo.sub_task_id,
      findings: last_branch_failure_detail(run, row.id)
    ]

    add_started(effects, execution, Runs.insert_job!(run, execution, Runs.build_payload(run, flow, node, opts)))
  end

  # A parked branch continues its own conversation: the session of the branch's latest execution
  # when that execution asked (`:needs_input`) — never the run-level one, which names one node.
  defp branch_resume_session(row) do
    latest =
      Repo.one(
        from e in NodeExecution,
          where: e.run_branch_id == ^row.id,
          order_by: [desc: e.id],
          limit: 1,
          select: %{outcome: e.outcome, session_id: e.session_id}
      )

    case latest do
      %{outcome: :needs_input, session_id: session_id} -> session_id
      _other -> nil
    end
  end

  # The run's queued/claimed jobs grouped by the branch row their execution belongs to.
  defp live_jobs_by_branch(run) do
    jobs = Runs.active_jobs(run)
    ids = Enum.map(jobs, & &1.node_execution_id)

    branch_of =
      Map.new(Repo.all(from e in NodeExecution, where: e.id in ^ids, select: {e.id, e.run_branch_id}))

    Enum.group_by(jobs, &Map.get(branch_of, &1.node_execution_id))
  end

  # RE410: the trailing run of outcome-nil executions of `node` in its current visit (the visit
  # a same-node re-entry continues), newest first — run-wide for a whole-run re-entry
  # (`run_branch_id` nil), that branch's own rows for a branch (RE437). Any row with an outcome —
  # a :failed, a :blocked usage-limit wait, the :needs_input this cap itself stamps — ends the
  # streak, which is what gives a human resume a fresh budget without a counter to reset.
  defp outcomeless_streak(run, node, run_branch_id) do
    visit = max_for(run, node, :visit) || 1

    from(e in NodeExecution,
      where: e.run_id == ^run.id and e.node_key == ^node and e.visit == ^visit,
      order_by: [desc: e.attempt]
    )
    |> within_branch(run_branch_id)
    |> Repo.all()
    |> Enum.take_while(&is_nil(&1.outcome))
  end

  # Not Runs.finalize_job!/2: that marks the job :done, but this attempt's job was just revoked.
  defp stamp_outcomeless_park!(execution) do
    execution
    |> Ecto.Changeset.change(
      outcome: :needs_input,
      finished_at: DateTime.truncate(DateTime.utc_now(), :second),
      detail: outcomeless_park_detail(execution.node_key)
    )
    |> Repo.update!()
  end

  defp outcomeless_park_detail(node_key) do
    "`#{node_key}` was re-entered #{Runs.max_outcomeless_reentries()} times in a row without any " <>
      "attempt reporting an outcome — usually a server restart killing the job it was running (RE410). " <>
      "Parked so it can't loop. Check whether the node's side effects (a deploy, a push) already " <>
      "happened, then answer to resume it."
  end

  # RE433: the ONE seam every dispatch goes through (start, re-entry, and a continuing outcome).
  # A job whose payload carries `refusal` — its node names a red or unknown agent — is never
  # announced to runners: it is recorded `:blocked` with that detail by `handle_info/2` below,
  # after the current message, so the server never calls itself.
  defp dispatch_job(%NodeJob{payload: %{"refusal" => _}} = job), do: send(self(), {:refuse_job, job.id})
  defp dispatch_job(job), do: Runs.dispatcher().dispatch(job)

  @impl true
  def handle_call({:report_outcome, job_id, attrs}, _from, state) do
    case report_outcome(Repo.get!(NodeJob, job_id), attrs, state) do
      {:continue, reply} ->
        {:reply, reply, state}

      {:stop, reply} ->
        refuse_pending_jobs(state)
        {:stop, :normal, reply, state}
    end
  end

  # RE358 Steer now. The comment is committed FIRST, in its own transaction, so the human's words
  # survive whatever follows (and `Activity.add_comment/2` broadcasts directly, so it must never run
  # inside a transaction that could roll back). Only then is the running attempt stopped and the
  # same node restarted — or, when there is no agent attempt to stop, the steer stays a note.
  def handle_call({:steer, actor, body, image_ids}, _from, state) do
    run = Repo.get!(Run, state.run_id)
    card = Repo.get!(Card, run.card_id)

    case Runs.add_steer_comment(card, {actor, body, image_ids}) do
      {:ok, comment} -> {:reply, {:ok, comment, steer_restart(state)}, state}
      {:error, changeset} -> {:reply, {:error, changeset}, state}
    end
  end

  # The steered re-entry: like {:reenter, _}'s same-node path — one transaction (stamp, revoke,
  # enter), then broadcast and dispatch after commit — but WITHOUT the RE410 cap (a human asked
  # for this restart; the `:steered` stamp ends the outcome-less streak anyway) and carrying the
  # stopped job's inputs forward instead of re-deriving them. The run's status is never written.
  defp steer_restart(state) do
    run = Repo.get!(Run, state.run_id)

    with :running <- run.status,
         {:ok, flow} <- Runs.load_flow(run),
         %{type: :agent} <- Enum.find(flow.nodes, &(&1.key == run.current_node)),
         [%NodeJob{} = job] <- Runs.active_jobs(run),
         %NodeExecution{outcome: nil, node_key: node_key} = execution when node_key == run.current_node <-
           Repo.get(NodeExecution, job.node_execution_id) do
      {:ok, {steered, next_execution, next_job}} = Repo.transaction(fn -> steer_rows!(run, flow, job, execution) end)

      board_id = Runs.board_id_of(run)
      Runs.broadcast_runs(board_id, {:node_finished, run, steered})
      Runs.broadcast_runs(board_id, {:node_started, run, next_execution})
      dispatch_job(next_job)
      :restarted
    else
      _nothing_to_restart -> :noted
    end
  end

  # Same visit, next attempt, same binding; the stopped attempt's session is resumed and its
  # findings / prior_detail ride along, so the restart differs from it only by the fresh guidance.
  defp steer_rows!(run, flow, job, execution) do
    steered = stamp_steered!(execution)
    Runs.revoke_active_jobs(run)

    attempt = max_in_visit(run, steered.node_key, steered.visit) + 1
    next = Runs.insert_execution!(run, steered.node_key, steered.visit, attempt, steered.sub_task_id)
    vars = job.payload["vars"] || %{}

    opts = [
      resume_session: steered.session_id,
      sub_task_id: steered.sub_task_id,
      findings: vars["findings"],
      prior_detail: vars["prior_detail"]
    ]

    {steered, next, Runs.insert_job!(run, next, Runs.build_payload(run, flow, steered.node_key, opts))}
  end

  # Not Runs.finalize_job!/2, for the same reason as stamp_outcomeless_park!/2: that marks the job
  # :done, but this attempt's job is revoked. No detail — the steer comment is the explanation.
  defp stamp_steered!(execution) do
    execution
    |> Ecto.Changeset.change(outcome: :steered, finished_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!()
  end

  # A server stopping right after a sibling's report on a parked run (RE437) would drop a
  # `{:refuse_job, _}` that report queued for itself, leaving the refused job queued forever
  # (runners never claim one). Record each refusal before stopping instead.
  defp refuse_pending_jobs(state) do
    receive do
      {:refuse_job, job_id} ->
        job = Repo.get!(NodeJob, job_id)
        _ = report_outcome(job, refusal_attrs(job), state)
        refuse_pending_jobs(state)
    after
      0 -> :ok
    end
  end

  defp refusal_attrs(job), do: %{outcome: :blocked, detail: job.payload["refusal"]}

  # A refused job's `:blocked` has no `resume_at`, so the Engine parks the run — no retry is
  # spent and nothing is requeued — and `park_effects/2` blocks the card with the refusal.
  @impl true
  def handle_info({:refuse_job, job_id}, state) do
    job = Repo.get!(NodeJob, job_id)

    case report_outcome(job, refusal_attrs(job), state) do
      {:stop, _reply} -> {:stop, :normal, state}
      {:continue, _reply} -> {:noreply, state}
    end
  end

  # The body of an outcome report, shared by the runner's report (`handle_call/3`) and a refused
  # job (`handle_info/2`) — the latter cannot go through `Runs.report_outcome/2`, which calls this
  # same server. Returns `{:continue, reply}` or `{:stop, reply}`.
  defp report_outcome(job, attrs, state) do
    run = Repo.get!(Run, state.run_id)

    cond do
      job.state not in NodeJob.active_states() or not Runs.report_accepted?(run, job) ->
        {:continue, {:error, :job_not_active}}

      match?({:error, :no_flow}, Runs.load_flow(run)) ->
        {:ok, execution} = Repo.transaction(fn -> Runs.finalize_job!(job, attrs) end)
        fail_effects(run, execution, "no_flow")
        {:stop, {:ok, Repo.get!(Run, run.id)}}

      true ->
        {:ok, flow} = Runs.load_flow(run)
        apply_outcome(run, flow, job, attrs)
    end
  end

  # One transaction: finalize the reported attempt, decide, write the next
  # run/execution/job rows. Card effects + broadcasts + dispatch happen after
  # commit (Hamaca.Cards manages its own transactions and pushes) — the sub_task
  # check-off is the one exception to "no card writes in here": its ROW WRITE
  # must land before Engine.decide runs (remaining_sub_tasks reads it on this
  # same connection), so check_off_sub_task/3 writes it directly and returns
  # the checked-off id; the broadcast for that write still waits until after
  # commit, alongside every other card effect below.
  defp apply_outcome(run, flow, job, attrs) do
    attrs =
      run
      |> override_no_op_success(flow, job, attrs)
      |> then(&override_missing_writes(run, flow, job, &1))

    {:ok, {decision, execution, effects}} =
      Repo.transaction(fn ->
        execution = Runs.finalize_job!(job, attrs)
        # Order matters: check off, THEN count, THEN route. One place, one ordering,
        # no second source of truth for "how many tasks are left".
        checked_off_id = check_off_sub_task(run, flow, execution)
        decision = decide(run, flow, execution)
        effects = new_effects() |> add_checked_off(checked_off_id) |> route(decision, run, flow, execution, job)
        {decision, execution, effects}
      end)

    settle(run, flow, effects, {decision, execution})
  end

  # After commit: card effects, timeline, broadcasts, dispatch, then the stop. `reported` is the
  # `{decision, execution}` an outcome report finalized, or nil for a re-entry.
  defp settle(run, flow, effects, reported) do
    run = Repo.get!(Run, run.id)
    board_id = Runs.board_id_of(run)
    notify_sub_task_checked_off(run, effects.checked_off)

    with {decision, execution} <- reported do
      log_failure_if_final(decision, run, execution)
      log_usage_limit_wait(decision, run, execution)
    end

    Enum.each(effects.finished, fn {control, control_decision} -> log_failure_if_final(control_decision, run, control) end)

    Enum.each(effects.failures, &log_failure(run, &1))

    # Timeline order: the reported execution, then the control nodes it resolved, then every
    # node that started.
    with {_decision, execution} <- reported, do: Runs.broadcast_runs(board_id, {:node_finished, run, execution})

    Enum.each(effects.finished, fn {control, _decision} ->
      Runs.broadcast_runs(board_id, {:node_finished, run, control})
    end)

    Enum.each(effects.started, fn {next_execution, next_job} ->
      Runs.broadcast_runs(board_id, {:node_started, run, next_execution})
      dispatch_job(next_job)
    end)

    case effects.stop do
      nil when run.status == :running ->
        {:continue, {:ok, run}}

      # RE437: a sibling's report on a parked run — the server never outlives it, so a parked run
      # holds no process between reports and resume_run/2's re-entry always starts fresh.
      nil ->
        {:stop, {:ok, run}}

      {:park, parked_on} ->
        # :needs_input (a question / an escalation edge) and :blocked (RE308) park identically.
        {:stop, {:ok, park_effects(run, parked_on)}}

      :finish ->
        finish_effects(run, flow)
        Runs.broadcast_runs(board_id, {:run_finished, run})
        {:stop, {:ok, run}}

      {:fail, failed_on} ->
        card_fail_effects(run, failed_on)
        Runs.broadcast_runs(board_id, {:run_finished, run})
        {:stop, {:ok, run}}
    end
  end

  # What one outcome did, accumulated inside apply_outcome's transaction and applied after commit
  # (RE437 — a decision may now start zero, one or several nodes):
  #
  #   * `finished`    — `{control_execution, its_decision | nil}` resolved on the way (fan_out,
  #                     fan_in), in order;
  #   * `started`     — every `{execution, job}` to broadcast and dispatch, in order;
  #   * `checked_off` — sub_task ids checked off (the reported loop tail, or a fan_in);
  #   * `failures`    — `:failure` timeline texts for branches that ended on a `{:fail, _}`;
  #   * `stop`        — nil (the run continues), `{:park, execution}`, `:finish` or
  #                     `{:fail, execution}`.
  defp new_effects, do: %{finished: [], started: [], checked_off: [], failures: [], stop: nil}

  defp add_started(effects, execution, job), do: %{effects | started: effects.started ++ [{execution, job}]}
  defp add_finished(effects, execution, decision), do: %{effects | finished: effects.finished ++ [{execution, decision}]}
  defp add_checked_off(effects, nil), do: effects
  defp add_checked_off(effects, id), do: %{effects | checked_off: effects.checked_off ++ [id]}
  defp add_failure(effects, text), do: %{effects | failures: effects.failures ++ [text]}

  # The first park wins: a second branch parking in the same pass is already on its row.
  defp park_on(%{stop: nil} = effects, execution), do: %{effects | stop: {:park, execution}}
  defp park_on(effects, _execution), do: effects

  # The engine's decision for a just-finalized (or just-resolved) execution, on its own scope of
  # history: its branch's rows when it is in a branch, the non-branch rows otherwise (RE437) —
  # which is every row for a flow with no region.
  defp decide(run, flow, execution) do
    opts =
      Runs.engine_opts(run) ++
        [sub_task_id: execution.sub_task_id, foreach_remaining: Runs.remaining_sub_tasks(run)]

    flow
    |> Engine.decide(outcome_history(run, execution.run_branch_id), execution, opts)
    |> branch_decision(execution)
  end

  # A valid flow cannot route a branch to `done` (validation forbids it); if one does anyway, the
  # branch fails rather than finishing the whole run under its siblings.
  defp branch_decision({:finish, :done}, %NodeExecution{run_branch_id: id}) when not is_nil(id),
    do: {:fail, "branch reached done"}

  defp branch_decision(decision, _execution), do: decision

  # Row writes per decision, inside apply_outcome's transaction, folded into `effects`.
  #
  # RE267: a {:requeue, node} means the node never ran, so the SAME work goes back on the queue —
  # the new job carries the blocked job's payload verbatim (its findings / prior_detail /
  # resume_session, and no "agent could not run" finding). Attempt +1 on the same visit and
  # binding, numbered exactly as a retry is; insert_job!/3 re-derives the exclusive pin, so an
  # exclusive run still waits for its own runner.
  defp route(effects, {:requeue, node}, run, _flow, execution, job) do
    next = insert_next_attempt!(run, node, execution)
    add_started(effects, next, Runs.insert_job!(run, next, job.payload))
  end

  defp route(effects, {:retry, node}, run, flow, execution, _job) do
    next = insert_next_attempt!(run, node, execution)
    opts = [findings: retry_findings(run, execution), sub_task_id: execution.sub_task_id]
    add_started(effects, next, Runs.insert_job!(run, next, Runs.build_payload(run, flow, node, opts)))
  end

  defp route(effects, {:transition, node, _guard}, run, flow, %NodeExecution{run_branch_id: id} = execution, _job)
       when not is_nil(id) do
    branch_transition(effects, node, run, flow, execution)
  end

  # `guard` is the `when` of the edge the engine followed. It rides on the decision so
  # binding_for/5 can key off it instead of re-selecting the edge here — a second copy of edge
  # selection would disagree with the engine on the RLY-179 degrade path, where
  # `execution.outcome` is the unrouted outcome and matches no edge at all.
  defp route(effects, {:transition, node, guard}, run, flow, execution, _job) do
    sub_task_id = binding_for(run, flow, node, guard, execution)

    if Flow.fan_out?(flow, node) do
      open_region!(effects, run, flow, node, sub_task_id)
    else
      run = run |> Ecto.Changeset.change(current_node: node) |> Repo.update!()
      next = Runs.insert_execution!(run, node, next_visit(run, node), 1, sub_task_id)
      job = Runs.insert_job!(run, next, Runs.build_payload(run, flow, node, transition_opts(execution, sub_task_id)))
      add_started(effects, next, job)
    end
  end

  # The run's own parked write happens AFTER ensure_card_blocked, in settle/4's stop handling —
  # not here (see park_effects/2). Inside a branch (RE437) the row parks with the node that
  # reported still current, and the run parks with it — but no sibling job is revoked, and a run
  # already parked by another branch only makes sure its card is blocked.
  defp route(effects, {:park, _why}, _run, _flow, %NodeExecution{run_branch_id: id} = execution, _job)
       when not is_nil(id) do
    RunBranch |> Repo.get!(id) |> park_row!()
    park_on(effects, execution)
  end

  defp route(effects, {:park, _why}, _run, _flow, execution, _job), do: park_on(effects, execution)

  defp route(effects, {:finish, :done}, run, _flow, _execution, _job) do
    Runs.close_run!(run, :done, nil)
    %{effects | stop: :finish}
  end

  # RE437: a branch that cannot go on ends `:failed` — the run is not closed, and the card is not
  # marked failed; the fan_in reports it. ONE `:failure` timeline entry carries the text.
  defp route(effects, {:fail, reason}, run, flow, %NodeExecution{run_branch_id: id} = execution, _job)
       when not is_nil(id) do
    detail = branch_failure_detail(execution.detail, reason)
    row = Repo.get!(RunBranch, id)
    end_branch!(row, :failed, detail)

    effects
    |> add_failure(detail)
    |> fill_region(run, flow, Repo.get!(NodeExecution, row.fan_out_execution_id))
  end

  defp route(effects, {:fail, reason}, run, _flow, execution, _job) do
    Runs.close_run!(run, :failed, reason)
    %{effects | stop: {:fail, execution}}
  end

  # A retry or a usage-limit requeue: attempt +1 of the same visit, binding and branch.
  defp insert_next_attempt!(run, node, execution) do
    Runs.insert_execution!(
      run,
      node,
      execution.visit,
      execution.attempt + 1,
      execution.sub_task_id,
      execution.run_branch_id
    )
  end

  # What a transition hands the next node: the execution's detail, and — when it failed — the
  # same detail as findings.
  defp transition_opts(execution, sub_task_id) do
    [
      prior_detail: execution.detail,
      findings: if(execution.outcome == :failed, do: execution.detail),
      sub_task_id: sub_task_id
    ]
  end

  defp branch_failure_detail(detail, reason) do
    if is_binary(detail) and String.trim(detail) != "", do: detail <> "\n\n" <> reason, else: reason
  end

  # ── fan-out regions (RE437) ─────────────────────────────────────────────────────────────

  @doc false
  # The start-transaction entry into a region (`Hamaca.Runs.start_run/3`, when the start edge
  # targets a `fan_out`): returns `{finished_control_executions, [{execution, job}]}` for the
  # caller to broadcast and dispatch after commit.
  def enter_region!(%Run{} = run, %Flow{} = flow, fan_out, sub_task_id) do
    effects = open_region!(new_effects(), run, flow, fan_out, sub_task_id)
    {Enum.map(effects.finished, &elem(&1, 0)), effects.started}
  end

  defp open_region!(effects, run, flow, fan_out, sub_task_id) do
    run = run |> Ecto.Changeset.change(current_node: fan_out) |> Repo.update!()
    fo = insert_control_execution!(run, fan_out, sub_task_id, :succeeded, nil)

    for branch <- Flow.region(flow, fan_out).branches do
      %RunBranch{
        run_id: run.id,
        fan_out_execution_id: fo.id,
        branch: branch.key,
        position: branch.position,
        state: :queued
      }
      |> RunBranch.changeset()
      |> Repo.insert!()
    end

    effects
    |> add_finished(fo, nil)
    |> fill_region(run, flow, fo)
  end

  # A fan_out or fan_in execution: resolved on the server, so it starts and finishes at once and
  # never has a job. `failure_signature` is stamped like finalize_job!/2 does, so a fan_in that
  # keeps failing the same way still trips the breaker.
  defp insert_control_execution!(run, node_key, sub_task_id, outcome, detail) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    %NodeExecution{
      run_id: run.id,
      node_key: node_key,
      visit: next_visit(run, node_key),
      attempt: 1,
      sub_task_id: sub_task_id,
      outcome: outcome,
      detail: detail,
      failure_signature: if(outcome == :failed, do: Engine.failure_signature(detail)),
      started_at: now,
      finished_at: now
    }
    |> NodeExecution.changeset()
    |> Repo.insert!()
  end

  # The scheduling step, run after a region opens and after each branch ends: unless a branch is
  # parked (or the run is — a sibling reporting while one waits on a human, RE437), start queued
  # rows by position until `max_parallel` run; join once every row ended.
  # The region is read from the LIVE flow at every step, so an edit mid-run is honoured — and a
  # queued branch the flow no longer has ends `:failed` instead of starting.
  # A region whose fan_out the live flow no longer has (a mid-run edit removed it) can neither
  # start a queued branch nor join, so the run fails — `close_run!/3` ends its open rows.
  defp fill_region(effects, run, flow, fo) do
    case Flow.region(flow, fo.node_key) do
      nil when run.status == :running -> region_removed!(effects, run, fo)
      nil -> effects
      region -> fill_region(effects, run, flow, fo, region)
    end
  end

  defp fill_region(effects, run, flow, fo, region) do
    rows = entry_rows(fo)
    next = Enum.find(rows, &(&1.state == :queued))

    cond do
      run.status != :running or Enum.any?(rows, &(&1.state == :parked)) ->
        effects

      Enum.all?(rows, &(&1.state == :ended)) ->
        join_region!(effects, run, flow, fo, region, rows)

      is_nil(next) or Enum.count(rows, &(&1.state == :running)) >= region.max_parallel ->
        effects

      Enum.any?(region.branches, &(&1.key == next.branch)) ->
        effects |> start_branch!(run, flow, fo, next) |> fill_region(run, flow, fo)

      true ->
        end_branch!(next, :failed, @branch_removed)
        fill_region(effects, run, flow, fo)
    end
  end

  defp region_removed!(%{stop: nil} = effects, run, fo) do
    Runs.close_run!(run, :failed, @region_removed)
    %{effects | stop: {:fail, fo}}
  end

  defp region_removed!(effects, _run, _fo), do: effects

  defp entry_rows(fo) do
    Repo.all(from b in RunBranch, where: b.fan_out_execution_id == ^fo.id, order_by: [asc: b.position])
  end

  defp start_branch!(effects, run, flow, fo, row) do
    row = row |> Ecto.Changeset.change(state: :running, current_node: row.branch) |> Repo.update!()
    execution = Runs.insert_execution!(run, row.branch, next_visit(run, row.branch), 1, fo.sub_task_id, row.id)
    job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, row.branch, region_entry_opts(run, fo)))
    add_started(effects, execution, job)
  end

  # Every branch of one region entry starts with the same vars, re-derived from history: what
  # came before the fan_out is the last outcome-bearing NON-branch execution preceding it.
  defp region_entry_opts(run, fo) do
    before =
      Repo.one(
        from e in NodeExecution,
          where: e.run_id == ^run.id and is_nil(e.run_branch_id) and not is_nil(e.outcome) and e.id < ^fo.id,
          order_by: [desc: e.id],
          limit: 1
      )

    [
      sub_task_id: fo.sub_task_id,
      prior_detail: before && before.detail,
      findings: if(before && before.outcome == :failed, do: before.detail)
    ]
  end

  # A transition out of a branch node: to the region's fan_in ends the branch with this node's
  # outcome; anywhere else stays inside the branch. `run.current_node` stays the fan_out key.
  defp branch_transition(effects, node, run, flow, execution) do
    row = Repo.get!(RunBranch, execution.run_branch_id)
    fo = Repo.get!(NodeExecution, row.fan_out_execution_id)

    if fan_in_of?(flow, fo, node) do
      outcome = if execution.outcome == :succeeded, do: :succeeded, else: :failed
      end_branch!(row, outcome, execution.detail)
      fill_region(effects, run, flow, fo)
    else
      row |> Ecto.Changeset.change(current_node: node) |> Repo.update!()
      next = Runs.insert_execution!(run, node, next_visit(run, node), 1, execution.sub_task_id, row.id)
      opts = transition_opts(execution, execution.sub_task_id)
      add_started(effects, next, Runs.insert_job!(run, next, Runs.build_payload(run, flow, node, opts)))
    end
  end

  defp fan_in_of?(flow, fo, node) do
    case Flow.region(flow, fo.node_key) do
      %{fan_in: fan_in} -> node == fan_in
      nil -> false
    end
  end

  defp park_row!(row), do: row |> Ecto.Changeset.change(state: :parked) |> Repo.update!()

  defp end_branch!(row, outcome, detail) do
    row
    |> Ecto.Changeset.change(state: :ended, current_node: nil, outcome: outcome, detail: detail)
    |> Repo.update!()
  end

  # Every row of the entry has ended: record the fan_in with the labelled join, check it off when
  # it is the foreach loop tail, then decide and route it like any other execution.
  defp join_region!(effects, run, flow, fo, region, rows) do
    run = run |> Ecto.Changeset.change(current_node: region.fan_in) |> Repo.update!()

    {outcome, detail} =
      Engine.join(Enum.map(rows, &%{branch: &1.branch, position: &1.position, outcome: &1.outcome, detail: &1.detail}))

    fi = insert_control_execution!(run, region.fan_in, fo.sub_task_id, outcome, detail)
    checked_off_id = check_off_sub_task(run, flow, fi)
    decision = decide(run, flow, fi)

    effects
    |> add_checked_off(checked_off_id)
    |> add_finished(fi, decision)
    |> route(decision, run, flow, fi, nil)
  end

  # A task is checked off ONLY after it passes every review in the loop — the loop
  # tail is the node whose outgoing edges carry a `when` guard. So a checked box on
  # the card means "reviewed", not "attempted" (strictly better than the grep-gate
  # it replaces, where the implementer checked its own box).
  #
  # Writes the row DIRECTLY (not via Hamaca.Cards.set_sub_task_done/3) so no
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
  defp notify_sub_task_checked_off(_run, []), do: :ok

  defp notify_sub_task_checked_off(run, _sub_task_ids) do
    card = Repo.get!(Card, run.card_id)
    Hamaca.Cards.notify_upserted(card)
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

  # Boot/park re-entry: fresh attempt of the current node, same visit.
  defp enter_same_node!(run, flow, resume_session) do
    node = run.current_node
    {visit, attempt} = same_visit_attempt(run, node)
    enter!(run, flow, node, visit, attempt, resume_session, :inherit)
  end

  # The `{visit, attempt}` of a fresh attempt of `node` in its latest visit — shared by the
  # run-level and the per-branch (RE437) same-node re-entry so the two can't drift.
  defp same_visit_attempt(run, node) do
    visit = max_for(run, node, :visit) || 1
    {visit, (max_in_visit(run, node, visit) || 0) + 1}
  end

  # Retry --at / advance re-entry: a fresh visit of the current node, attempt 1.
  defp enter_new_visit!(run, flow, resume_session, binding) do
    node = run.current_node
    enter!(run, flow, node, next_visit(run, node), 1, resume_session, binding)
  end

  # RLY-189: every re-entry carries the last failure forward as `findings`, exactly as
  # apply_decision({:retry, ...}) already does — a node re-entered after a failure must
  # know why, and a plain re-entry used to start blind.
  defp enter!(run, flow, node, visit, attempt, resume_session, binding) do
    sub_task_id = reentry_binding(run, node, binding)
    execution = Runs.insert_execution!(run, node, visit, attempt, sub_task_id)

    opts = [
      resume_session: resume_session,
      sub_task_id: sub_task_id,
      findings: last_failure_detail(run)
    ]

    job = Runs.insert_job!(run, execution, Runs.build_payload(run, flow, node, opts))
    {execution, job}
  end

  # Which iteration a RE-ENTRY binds to. `:inherit` is every existing re-entry — the node's most
  # recent binding, so a resumed/retried node lands on the SAME task (RE252). `:rebind` is
  # RE310's human hatch, and the only caller that may re-derive the cursor.
  defp reentry_binding(run, _node, :rebind), do: Runs.next_sub_task_id(run)
  defp reentry_binding(run, node, :inherit), do: Runs.current_sub_task_id(run, node)

  # RLY-194 / RE310: a node that must produce commits (expects_commits) but reported :succeeded
  # with HEAD unmoved from before the VISIT ran did not do its work — UNLESS it can prove the work
  # is already on the branch because this same node already committed for the thing it is bound
  # to. Rewrite the outcome to :failed BEFORE finalize_job! — the seam is load-time deliberate: it
  # is the only place with the flow node (expects_commits), the run (the baselines) and the raw
  # attrs before finalize_job! computes the failure_signature (which it does only for :failed).
  # Fail open on nil: a missing sha on either side is not evidence of a lie.
  #
  #     not expects_commits, or HEAD moved  -> unchanged (as today)
  #     HEAD unmoved, claim, prior commits  -> ACCEPT :succeeded   (RE310)
  #     HEAD unmoved, otherwise             -> rewrite to :failed
  #
  # Default-deny survives. On a node's FIRST visit for a binding the binding baseline EQUALS the
  # visit baseline, so a claim is always rejected there — the RLY-194 case that once merged a
  # subset of its work (a node that has never committed anything) is caught exactly as before.
  # Only a node that demonstrably already committed for this binding can assert its way out,
  # which is precisely the RE306 shape.
  defp override_no_op_success(run, flow, job, %{outcome: :succeeded, git_sha: sha} = attrs) when is_binary(sha) do
    node = Enum.find(flow.nodes, &(&1.key == job.node_key))

    if node && node.expects_commits && baseline_sha(run, job) == sha do
      resolve_no_op(run, job, sha, attrs)
    else
      attrs
    end
  end

  defp override_no_op_success(_run, _flow, _job, attrs), do: attrs

  # The three ways a stalled expects_commits node ends, and the three details a retry receives as
  # its findings (RE251) — in ONE place, because a wrong message here is what kept RE306 going in
  # circles for four attempts and two human answers.
  defp resolve_no_op(run, job, sha, attrs) do
    case {attrs[:no_changes] == true, binding_produced_commits?(run, job, sha)} do
      {true, true} -> attrs
      {true, false} -> Map.merge(attrs, %{outcome: :failed, detail: no_changes_unproven_detail(job.node_key)})
      {false, true} -> Map.merge(attrs, %{outcome: :failed, detail: already_committed_detail(job.node_key, sha)})
      {false, false} -> Map.merge(attrs, %{outcome: :failed, detail: no_op_detail(job.node_key, sha)})
    end
  end

  # Can this node prove it already committed for what it is currently bound to? True only when the
  # BINDING baseline resolves and differs from the reported sha.
  #
  # Note the deliberate asymmetry with the guard above: that one FAILS OPEN on a nil sha ("a
  # missing row is not evidence of a lie"), this one FAILS CLOSED. The burden of proof is on the
  # claimant, so an unresolvable binding baseline rejects the claim rather than honouring it.
  defp binding_produced_commits?(run, job, sha) do
    case binding_baseline_sha(run, job) do
      baseline when is_binary(baseline) -> baseline != sha
      nil -> false
    end
  end

  # The git_sha of the most recent outcome-bearing execution with a non-nil sha PRECEDING
  # `boundary_id` — "HEAD before that row". Both baselines below are this same query at a
  # different boundary, so it is written once (AGENTS.md). A nil `boundary_id` means the boundary
  # could not be resolved and degrades to the unbounded lookup; what each CALLER does with a nil
  # RESULT differs on purpose, see below.
  #
  # Inside a branch (RE437) only that branch's rows count, so a branch's first node has no
  # baseline and fails open.
  defp baseline_before(run, boundary_id, run_branch_id) do
    latest =
      within_branch(
        from(e in NodeExecution,
          where: e.run_id == ^run.id and not is_nil(e.git_sha),
          order_by: [desc: e.id],
          limit: 1,
          select: e.git_sha
        ),
        run_branch_id
      )

    query = if boundary_id, do: where(latest, [e], e.id < ^boundary_id), else: latest

    Repo.one(query)
  end

  # HEAD before this VISIT was entered — not "before this attempt" (the just-finalized row is not
  # written yet, and even if it were it carries a nil git_sha until finalize).
  #
  # RE298: the per-VISIT boundary is the load-bearing part. An attempt that commits and then dies
  # before writing its outcome file is recorded :failed carrying the POST-work sha; baselining on
  # that row leaves the retry structurally unable to pass the guard. Per-visit, the visit's real
  # commit still counts, while a visit that genuinely committed nothing is still caught. Not
  # same-node across visits: a spec_review between two implements reports the identical sha. Fall
  # back to the unbounded lookup when the boundary can't be resolved — a missing row is not
  # evidence of a lie.
  defp baseline_sha(run, job), do: baseline_before(run, visit_first_attempt_id(run, job), job_branch_id(job))

  # RE310: HEAD before this BINDING was first entered — the wider boundary a `--no-changes` claim
  # is checked against. Returns nil when the binding cannot be resolved, which
  # `binding_produced_commits?/3` reads as "unproven" (fail closed). It deliberately does NOT
  # degrade to the unbounded lookup the way baseline_sha/2 does: that lookup can return a
  # different node's sha and would turn an unresolvable binding into a free pass.
  defp binding_baseline_sha(run, job) do
    case binding_first_execution_id(run, job) do
      nil -> nil
      id -> baseline_before(run, id, job_branch_id(job))
    end
  end

  # The FIRST execution row of this job's binding. Binding is defined here, once, and generalises
  # the foreach case rather than special-casing it:
  #
  #   * `sub_task_id` present -> the first execution in this run with the same node_key AND
  #     sub_task_id (the foreach shape: this node's first go at THIS task);
  #   * `sub_task_id` nil     -> the first execution in this run with the same node_key (this
  #     node's first visit in the run — final_fix, github_fix).
  defp binding_first_execution_id(run, job) do
    case Repo.get(NodeExecution, job.node_execution_id) do
      %NodeExecution{node_key: node_key, sub_task_id: sub_task_id, run_branch_id: run_branch_id} ->
        base =
          within_branch(
            from(e in NodeExecution,
              where: e.run_id == ^run.id and e.node_key == ^node_key,
              order_by: [asc: e.id],
              limit: 1,
              select: e.id
            ),
            run_branch_id
          )

        query = if sub_task_id, do: where(base, [e], e.sub_task_id == ^sub_task_id), else: base

        Repo.one(query)

      nil ->
        nil
    end
  end

  # The branch the job's execution runs in (RE437), or nil.
  defp job_branch_id(job) do
    Repo.one(from e in NodeExecution, where: e.id == ^job.node_execution_id, select: e.run_branch_id)
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
  # construction — the same property Hamaca.Runs.Engine is built on.
  #
  # Inside a branch (RE437) only that branch's executions count as the origin.
  defp origin_findings(run, %NodeExecution{node_key: node_key, visit: visit, run_branch_id: run_branch_id}) do
    with id when is_integer(id) <- visit_first_attempt_id(run.id, node_key, visit),
         {:failed, detail} <-
           from(e in NodeExecution,
             where: e.run_id == ^run.id and e.id < ^id and not is_nil(e.outcome),
             order_by: [desc: e.id],
             limit: 1,
             select: {e.outcome, e.detail}
           )
           |> within_branch(run_branch_id)
           |> Repo.one() do
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

  # (2) RE306/RE310: the node's OWN earlier commit for this binding IS the work, so it cannot move
  # HEAD again. Same `no_op_success` machine token as (1), deliberately a DIFFERENT sentence — and
  # therefore a different failure_signature and a different circuit-breaker bucket, which is
  # correct: they are different situations. This is the just-in-time discoverability channel for
  # `--no-changes`: the agent reads it as findings at the exact moment it is stuck.
  defp already_committed_detail(node_key, sha) do
    short = String.slice(sha, 0, 7)

    "`#{node_key}` reported success but produced no commits — HEAD is still `#{short}`. " <>
      "This task's work appears to be committed already (`#{short}` was produced by an earlier " <>
      "visit of this node for this task), so it cannot move HEAD again. If there is genuinely " <>
      "nothing left to change, report `relay outcome succeeded --no-changes`; if there is, " <>
      "make the change and commit it. (no_op_success: #{node_key})"
  end

  # (3) The claim the engine could not corroborate.
  defp no_changes_unproven_detail(node_key) do
    "`#{node_key}` reported `--no-changes`, but this node has not produced a commit for this " <>
      "task in this run, so there is nothing that could already be done. Do the work and commit " <>
      "it. (no_changes_unproven: #{node_key})"
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

    case Hamaca.Cards.blank_contract_fields(card, declared) do
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
  # failed: a re-entry after a park-on-question or a success carries no findings. A
  # `:blocked` row (RE308) is skipped, not read: the node never ran, so the finding a
  # retry needs is whatever sent the node here — never "the agent could not run". A
  # server-only row (RE358's `:steered`) is skipped too: a human stopping an attempt says
  # nothing about why the node is here, so a re-entry after a steer keeps the real failure.
  defp last_failure_detail(run), do: run |> last_outcome_query() |> failure_detail()

  # The same rule scoped to one branch's executions (RE437): what a re-entered branch is handed.
  defp last_branch_failure_detail(run, run_branch_id),
    do: run |> last_outcome_query() |> within_branch(run_branch_id) |> failure_detail()

  defp last_outcome_query(run) do
    skipped = [:blocked | NodeExecution.server_only_outcomes()]

    from e in NodeExecution,
      where: e.run_id == ^run.id and not is_nil(e.outcome) and e.outcome not in ^skipped,
      order_by: [desc: e.id],
      limit: 1,
      select: %{outcome: e.outcome, detail: e.detail}
  end

  defp failure_detail(query) do
    case Repo.one(query) do
      %{outcome: :failed, detail: detail} -> detail
      _other -> nil
    end
  end

  # The history Engine.decide/4 sees (RE437): a branch execution's own branch, or — for every
  # other execution — the non-branch rows, which is the whole run for a flow with no region.
  defp outcome_history(run, run_branch_id) do
    from(e in NodeExecution, where: e.run_id == ^run.id and not is_nil(e.outcome), order_by: [asc: e.id])
    |> history_scope(run_branch_id)
    |> Repo.all()
  end

  defp history_scope(query, nil), do: where(query, [e], is_nil(e.run_branch_id))
  defp history_scope(query, run_branch_id), do: within_branch(query, run_branch_id)

  # The narrower scope the retry-findings and commit-guard lookups take (RE437): inside a branch
  # they see only that branch; outside one they keep today's run-wide view.
  defp within_branch(query, nil), do: query
  defp within_branch(query, run_branch_id), do: where(query, [e], e.run_branch_id == ^run_branch_id)

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

  # A terminal failure's :failure entry belongs to Hamaca.Cards.mark_failed/3 — it
  # carries the detail in `meta`, which the diagnosis surfaces read. Logging here
  # too would double it in the timeline (RLY-179).
  defp log_failure_if_final({:fail, _reason}, _run, _execution), do: :ok

  # RE308: an infrastructure park is not a failure the engine routed, but its cause (an expired
  # login, a usage limit) must reach the card's timeline like any other stop.
  defp log_failure_if_final({:park, :blocked}, run, execution),
    do: log_failure(run, execution.detail || "agent could not run")

  defp log_failure_if_final(_decision, run, %NodeExecution{outcome: :failed} = execution),
    do: log_failure(run, execution.detail || "node failed")

  defp log_failure_if_final(_decision, _run, _execution), do: :ok

  defp log_failure(run, text) do
    card = Repo.get!(Card, run.card_id)
    {:ok, _entry} = Hamaca.Activity.log(card, %{type: :failure, actor: :agent, text: text})
    :ok
  end

  # RE267: a usage-limit wait is not a failure, but a human glancing at the card must see why
  # nothing is moving — so one `:action` line, never a `:failure`. The count is the engine's own
  # (`usage_limit_waits/2`), read back after commit; the new attempt has no outcome yet, so it is
  # not in the history.
  defp log_usage_limit_wait({:requeue, node}, run, execution) do
    wait = Engine.usage_limit_waits(outcome_history(run, execution.run_branch_id), execution)

    text =
      "usage limit — waiting for reset at #{Runs.resume_time_label(execution.resume_at)}; " <>
        "node #{node} will re-run (wait #{wait} of #{Engine.max_usage_limit_waits()})"

    card = Repo.get!(Card, run.card_id)
    {:ok, _entry} = Hamaca.Activity.log(card, %{type: :action, actor: :agent, text: text})
    :ok
  end

  defp log_usage_limit_wait(_decision, _run, _execution), do: :ok

  # The one park sequence, shared by an engine `{:park, _}` and the RE410 outcome-less re-entry
  # cap; returns the parked run so each caller builds its own GenServer return.
  #
  # Card effect BEFORE the run's own parked write (unlike the other terminal branches): the run
  # row still reads :running in Postgres while ensure_card_blocked commits, so a concurrent
  # Listener reconciliation (RLY-132) sees a run it must leave alone rather than a
  # parked/needs_input run paired with a not-yet-blocked card — which it would misread as "the
  # answer already arrived" and resume.
  defp park_effects(%Run{status: :parked} = run, execution) do
    ensure_card_blocked(run, execution)
    run
  end

  defp park_effects(run, execution) do
    ensure_card_blocked(run, execution)

    run =
      case Transitions.transition(run, [:running], :parked, set: [parked_reason: :needs_input]) do
        {:ok, parked} -> parked
        {:error, :not_in_expected_state} -> Repo.get!(Run, run.id)
      end

    Runs.broadcast_runs(Runs.board_id_of(run), {:run_parked, run})
    run
  end

  # In the real flow the agent has already blocked the card via the
  # needs-input API; ensure it idempotently with the outcome detail as the
  # question fallback. The Listener's resume rule compares against
  # :needs_input, so reconciliation self-heals either ordering.
  defp ensure_card_blocked(run, execution) do
    card = Repo.get!(Card, run.card_id)

    if card.status != :needs_input do
      {:ok, _card} = Hamaca.Cards.request_input(card, execution.detail || "The agent needs input.", :agent)
    end

    :ok
  end

  # Run closed :done → the card lands on the stage after the flow's, worked out from the
  # board's order NOW (RE429 — `Hamaca.Flows.neighbours/1` reads it fresh, so a reorder during
  # the run is honoured). The move's snap sets the arrival status (e.g. :in_review at
  # Spec:Review). A flow on the board's last stage has nowhere to land: the card stays put.
  defp finish_effects(run, flow) do
    case Flows.neighbours(flow).lands_on do
      nil ->
        :ok

      lands_on ->
        card = Repo.get!(Card, run.card_id)
        {:ok, _card} = Hamaca.Cards.move_card(card, lands_on, 1_000_000, :agent)
        :ok
    end
  end

  # Run failed → flag the card with the node's actual output so a human sees it at
  # once. RLY-179: this is `mark_failed/3`, not `request_input/3` — the run is
  # terminal, so a `:question` would invite an answer that cannot resume anything.
  # The scheduler skips `:failed` cards by rule, so a card whose last run died is
  # never silently re-pulled.
  #
  # Unlike ./relay's flag() (which wraps the detail in "[auto] stage failed: …
  # a human needs to look" framing), this posts the bare detail.
  #
  # `apply_decision({:fail, _})` already closed the run in this transaction and the caller
  # broadcasts, so only the card half runs here — via `Runs.mark_card_failed/2`, the same
  # definition `Runs.fail_run/3` and the reaper use, so the two failure routes cannot drift on
  # the detail a human ends up reading (RE297).
  defp card_fail_effects(run, execution) do
    Runs.mark_card_failed(run, execution && execution.detail)
  end

  # Terminal path shared with the no-flow branches. `Runs.fail_run/3` owns the close + card
  # mark + broadcast (RE297, one definition used by the engine and the reaper alike); the node's
  # own output is what the card should show, so it is passed as the card detail — `reason` needs
  # no mention, since `fail_run/3` stores it as `failure_detail` and falls back to it.
  defp fail_effects(run, execution, reason) do
    Runs.fail_run(run, reason, execution && execution.detail)
    :ok
  end
end
