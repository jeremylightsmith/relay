defmodule Relay.Runs.OutcomelessReentryTest do
  @moduledoc """
  RE410: a node re-entered over and over without any attempt reporting an outcome parks on
  `needs_input` after `Relay.Runs.max_outcomeless_reentries/0` consecutive outcome-less attempts,
  instead of looping forever (RE408 looped 58×).
  """
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Instance
  alias Schemas.Card
  alias Schemas.Comment
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  setup do
    # Engine FIRST, before any run exists — see reenter_findings_test.exs for why.
    start_engine!()
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Outcome-less Board"})
    {:ok, flow} = board |> Relay.Flows.get_flow!("spec") |> Relay.Flows.enable_flow()
    stage = Enum.find(board.stages, &(&1.name == "Next up"))

    {:ok, card} =
      Relay.Cards.create_card(stage, %{
        title: "Do not loop forever",
        spec: "# Spec (pre-seeded — the spec flow's brainstorm declares it writes this, RE244)",
        acceptance_criteria: "1. It works."
      })

    :ok = Runs.subscribe(board.id)
    %{user: user, board: board, flow: flow, card: card}
  end

  defp park_detail(node) do
    "`#{node}` was re-entered #{Runs.max_outcomeless_reentries()} times in a row without any attempt " <>
      "reporting an outcome — usually a server restart killing the job it was running (RE410). " <>
      "Parked so it can't loop. Check whether the node's side effects (a deploy, a push) already " <>
      "happened, then answer to resume it."
  end

  defp stop_server(run) do
    case Registry.lookup(Instance.current().registry, run.id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}

      [] ->
        :ok
    end
  end

  defp start_server(run, mode) do
    instance = Instance.current()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        instance.run_supervisor,
        {Relay.Runs.RunServer, run_id: run.id, mode: mode, registry: instance.registry, callers: Instance.callers()}
      )

    pid
  end

  defp force_reenter(run) do
    stop_server(run)
    start_server(run, {:reenter, nil})
  end

  defp executions(run) do
    Repo.all(from e in NodeExecution, where: e.run_id == ^run.id, order_by: [asc: e.attempt, asc: e.visit])
  end

  defp jobs(run), do: Repo.all(from j in NodeJob, where: j.run_id == ^run.id)

  # start + two re-entries: attempts 1..cap of brainstorm visit 1, all outcome nil.
  defp build_streak_at_cap(ctx) do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}

    for _ <- 2..Runs.max_outcomeless_reentries()//1 do
      force_reenter(run)
      assert_receive {:dispatched, %NodeJob{}}
    end

    run
  end

  defp park_by_cap(ctx) do
    run = build_streak_at_cap(ctx)
    pid = force_reenter(run)
    ref = Process.monitor(pid)
    assert_receive {:run_parked, %Run{status: :parked, parked_reason: :needs_input} = parked}
    assert parked.id == run.id
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    run
  end

  test "the re-entry after max_outcomeless_reentries outcome-less attempts parks needs_input", ctx do
    cap = Runs.max_outcomeless_reentries()
    run = park_by_cap(ctx)
    refute_receive {:dispatched, _}, 200

    execs = executions(run)
    assert length(execs) == cap
    assert Enum.all?(execs, &(&1.node_key == "brainstorm" and &1.visit == 1))
    assert [nil, nil] = execs |> Enum.take(cap - 1) |> Enum.map(& &1.outcome)

    last = List.last(execs)
    assert last.attempt == cap
    assert last.outcome == :needs_input
    assert last.finished_at
    assert last.detail == park_detail("brainstorm")

    all_jobs = jobs(run)
    assert length(all_jobs) == cap
    assert Enum.all?(all_jobs, &(&1.state == :revoked))
    assert Runs.active_job(run) == nil

    card = Repo.get!(Card, ctx.card.id)
    assert card.status == :needs_input

    question =
      Repo.one(
        from c in Comment,
          where: c.card_id == ^card.id and c.kind == :question,
          order_by: [desc: c.id],
          limit: 1
      )

    assert question.body == park_detail("brainstorm")
    assert question.body =~ "brainstorm"
    assert question.body =~ "re-entered 3 times"

    assert Registry.lookup(Instance.current().registry, run.id) == []
  end

  test "answering the cap park resumes with one fresh attempt that does not re-park", ctx do
    run = park_by_cap(ctx)

    card = Relay.Cards.get_card(ctx.board, ctx.card.id)
    {:ok, _card} = Relay.Cards.answer_input(card, "the deploy already happened", {:user, ctx.user.id})

    assert_receive {:run_resumed, %Run{status: :running}}, 1_000
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm", state: :queued} = fresh}, 1_000

    execution = Repo.get!(NodeExecution, fresh.node_execution_id)
    assert execution.visit == 1
    assert execution.attempt == Runs.max_outcomeless_reentries() + 1
    assert execution.outcome == nil

    refute_receive {:run_parked, _}, 200
    assert Runs.get_run!(run.id).status == :running
  end

  test "an outcome inside the visit breaks the streak", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}

    force_reenter(run)
    assert_receive {:dispatched, %NodeJob{} = job2}

    {:ok, _run} = Runs.report_outcome(job2, %{outcome: :failed, detail: "boom"})
    assert_receive {:dispatched, %NodeJob{}}

    force_reenter(run)
    assert_receive {:dispatched, %NodeJob{}}

    force_reenter(run)
    assert_receive {:dispatched, %NodeJob{node_key: "brainstorm"} = job5}
    assert Repo.get!(NodeExecution, job5.node_execution_id).attempt == 5
    refute_receive {:run_parked, _}, 200

    outcomeless = run |> executions() |> Enum.filter(&(&1.attempt < 5 and is_nil(&1.outcome)))
    assert Enum.map(outcomeless, & &1.attempt) == [1, 3, 4]
  end

  test "a streak one below the cap still dispatches", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{}}

    for _ <- 1..(Runs.max_outcomeless_reentries() - 1)//1 do
      force_reenter(run)
      assert_receive {:dispatched, %NodeJob{}}
    end

    assert Runs.get_run!(run.id).status == :running
    refute_receive {:run_parked, _}, 200
  end

  test "a fresh-visit re-entry never runs the cap check", ctx do
    run = build_streak_at_cap(ctx)
    stop_server(run)

    start_server(run, {:reenter_new_visit, nil})

    assert_receive {:dispatched, %NodeJob{} = job}
    execution = Repo.get!(NodeExecution, job.node_execution_id)
    assert execution.visit == 2
    assert execution.attempt == 1
    refute_receive {:run_parked, _}, 200
  end

  test "an engine needs_input park still blocks the card through the shared helper", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, %NodeJob{} = job}

    {:ok, _run} =
      Runs.report_outcome(job, %{outcome: :needs_input, detail: "Which auth model?", session_id: "s1"})

    assert_receive {:run_parked, %Run{parked_reason: :needs_input} = parked}
    assert parked.id == run.id

    card = Repo.get!(Card, ctx.card.id)
    assert card.status == :needs_input

    assert Repo.exists?(
             from c in Comment,
               where: c.card_id == ^card.id and c.kind == :question and c.body == "Which auth model?"
           )
  end
end
