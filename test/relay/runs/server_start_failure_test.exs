defmodule Relay.Runs.ServerStartFailureTest do
  @moduledoc """
  RE412: a run whose RunServer cannot start (`DynamicSupervisor.start_child/2` returns an error)
  fails visibly — run and card `:failed` with an actionable detail — instead of raising a
  `MatchError` and leaving a `:running` run with no server. And `RunServer.init/1` refuses to
  start for a run that is no longer `:running`.
  """
  use Relay.DataCase, async: true

  import Ecto.Query

  alias Relay.Runs
  alias Relay.Runs.FakeDispatcher
  alias Relay.Runs.Instance
  alias Schemas.Card
  alias Schemas.NodeExecution
  alias Schemas.NodeJob
  alias Schemas.Run

  @moduletag :capture_log

  @detail_prefix "run server failed to start: "

  # Dispatch is asynchronous (the RunServer sends it); the 100ms default flakes under a full
  # parallel suite.
  @dispatch_timeout 1_000

  setup do
    FakeDispatcher.register(self())

    user = insert(:user)
    {:ok, board} = Relay.Boards.create_board(user, %{name: "Server Start Board"})
    flow = dead_end_flow(board)
    card = new_card(board, "Start my server")
    start_engine!()
    await_engine_boot!()
    %{board: board, flow: flow, card: card, user: user}
  end

  # A single "brainstorm" node with max_retries: 1 and no :failed edge, so two failures end the
  # run :failed (copied from retry_test.exs).
  defp dead_end_flow(board) do
    next_up = Enum.find(board.stages, &(&1.name == "Next up"))
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    review = Enum.find(board.stages, &(&1.name == "Spec:Review"))

    {:ok, flow} =
      Relay.Flows.create_flow(board, %{
        key: "dead-end",
        isolation: :shared_clean,
        pulls_from_stage_id: next_up.id,
        works_in_stage_id: spec.id,
        lands_on_stage_id: review.id,
        nodes: [%{key: "brainstorm", type: :agent, run: "/brainstorm {ref}", max_retries: 1}],
        edges: [%{from: "start", to: "brainstorm"}, %{from: "brainstorm", to: "done", on: :succeeded}]
      })

    {:ok, flow} = Relay.Flows.enable_flow(flow)
    flow
  end

  defp new_card(board, title) do
    stage = Enum.find(board.stages, &(&1.name == "Next up"))
    {:ok, card} = Relay.Cards.create_card(stage, %{title: title})
    card
  end

  defp failed_run(card, flow) do
    {:ok, _run} = Runs.start_run(card, flow)
    assert_receive {:dispatched, %NodeJob{} = first}
    {:ok, _run} = Runs.report_outcome(first, %{outcome: :failed, detail: "first boom"})
    assert_receive {:dispatched, %NodeJob{} = second}
    {:ok, run} = Runs.report_outcome(second, %{outcome: :failed, detail: "final boom"})
    assert run.status == :failed
    Runs.get_run!(run.id)
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

  defp start_child(run, mode) do
    instance = Instance.current()

    DynamicSupervisor.start_child(
      instance.run_supervisor,
      {Relay.Runs.RunServer, run_id: run.id, mode: mode, registry: instance.registry, callers: Instance.callers()}
    )
  end

  defp assert_server_start_failed(run_id) do
    run = Repo.get!(Run, run_id)
    assert run.status == :failed
    assert String.starts_with?(run.failure_detail, @detail_prefix)
    assert run.failure_detail =~ ":max_children"
    run
  end

  defp card_status(card_id), do: Repo.get!(Card, card_id).status

  test "a refused start fails the run and its card instead of raising", ctx do
    refuse_run_server_starts!()

    assert {:error, :run_server_unavailable} = Runs.start_run(ctx.card, ctx.flow)

    assert [run] = Repo.all(from r in Run, where: r.card_id == ^ctx.card.id)
    assert_server_start_failed(run.id)
    assert [%NodeJob{state: :revoked}] = Repo.all(from j in NodeJob, where: j.run_id == ^run.id)
    assert card_status(ctx.card.id) == :failed

    assert_receive {:revoked, %NodeJob{}}
    refute_receive {:dispatched, _}
  end

  test "a refused resume of a needs_input park fails the run and its card", ctx do
    {:ok, _} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, job}, @dispatch_timeout
    {:ok, _} = Runs.report_outcome(job, %{outcome: :needs_input, detail: "which one?"})
    parked = Runs.get_run!(job.run_id)
    assert parked.status == :parked
    refuse_run_server_starts!()

    assert {:error, :run_server_unavailable} = Runs.resume_run(parked)

    assert_server_start_failed(parked.id)
    assert card_status(ctx.card.id) == :failed
  end

  test "a refused retry fails the revived run again and keeps its retry count", ctx do
    run = failed_run(ctx.card, ctx.flow)
    assert run.retries == 0
    refuse_run_server_starts!()

    assert {:error, :run_server_unavailable} = Runs.retry_run(run)

    failed = assert_server_start_failed(run.id)
    assert failed.retries == 1
    assert card_status(ctx.card.id) == :failed
  end

  test "the run_server_unavailable refusal has a code and a human message" do
    assert Runs.retry_refusal_message(:run_server_unavailable) ==
             "The engine couldn't start this run's server. The run is marked failed — try again, " <>
               "and check the server logs if it keeps happening."

    assert Runs.retry_refusal_code(:run_server_unavailable) == "run_server_unavailable"
  end

  test "boot resume fails every run whose server cannot start and returns :ok", ctx do
    other = new_card(ctx.board, "Start my other server")
    {:ok, run_a} = Runs.start_run(ctx.card, ctx.flow)
    {:ok, run_b} = Runs.start_run(other, ctx.flow)
    assert_receive {:dispatched, _}, @dispatch_timeout
    assert_receive {:dispatched, _}, @dispatch_timeout
    stop_server(run_a)
    stop_server(run_b)
    refuse_run_server_starts!()

    assert :ok = Runs.resume_all()

    assert_server_start_failed(run_a.id)
    assert_server_start_failed(run_b.id)
    assert card_status(ctx.card.id) == :failed
    assert card_status(other.id) == :failed
  end

  test "RunServer refuses to start for a run that is no longer :running", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, job}, @dispatch_timeout
    stop_server(run)
    Runs.close_run!(Runs.get_run!(run.id), :cancelled, nil)

    assert :ignore = start_child(run, {:dispatch, job.id})
    refute_receive {:dispatched, _}
  end

  test "RunServer still starts for a :running run", ctx do
    {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
    assert_receive {:dispatched, _}, @dispatch_timeout
    stop_server(run)

    assert {:ok, pid} = start_child(run, :attach)
    assert is_pid(pid)
  end

  describe "report_outcome/2" do
    test "a refused attach start answers run_server_unavailable and leaves the job and run intact", ctx do
      {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
      assert_receive {:dispatched, job}, @dispatch_timeout
      refuse_run_server_starts!()

      assert {:error, :run_server_unavailable} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "ok"})

      assert Runs.get_run!(run.id).status == :running
      assert Repo.get!(NodeJob, job.id).state == :queued
      assert execution_outcome(job) == nil
    end

    test "a server that stops under the call is retried and the closed run answers job_not_active", ctx do
      {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
      assert_receive {:dispatched, job}, @dispatch_timeout
      [{pid, _}] = Registry.lookup(Instance.current().registry, run.id)
      :ok = :sys.suspend(pid)

      task = Task.async(fn -> Runs.report_outcome(job, %{outcome: :succeeded, detail: "late"}) end)
      wait_for_queued_call(pid, 200)
      Runs.close_run!(Runs.get_run!(run.id), :cancelled, nil)
      GenServer.stop(pid, :normal)

      assert {:error, :job_not_active} = Task.await(task)
      refute Repo.get!(NodeJob, job.id).state == :done
    end

    test "handle_call rechecks the run status and refuses a closed run's late report", ctx do
      {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
      assert_receive {:dispatched, job}, @dispatch_timeout
      [{pid, _}] = Registry.lookup(Instance.current().registry, run.id)
      Runs.close_run!(Runs.get_run!(run.id), :cancelled, nil)

      assert {:error, :job_not_active} =
               GenServer.call(pid, {:report_outcome, job.id, %{outcome: :succeeded, detail: "late"}})

      refute Repo.get!(NodeJob, job.id).state == :done
      assert execution_outcome(job) == nil
    end

    test "a stopped server is lazily restarted by the attach path", ctx do
      {:ok, run} = Runs.start_run(ctx.card, ctx.flow)
      assert_receive {:dispatched, job}, @dispatch_timeout
      stop_server(run)
      assert Runs.get_run!(run.id).status == :running
      assert Repo.get!(NodeJob, job.id).state == :queued

      assert {:ok, %Run{}} = Runs.report_outcome(job, %{outcome: :succeeded, detail: "ok"})
      assert Repo.get!(NodeJob, job.id).state == :done
    end

    test "no hard match on ensure_server remains in Relay.Runs" do
      source = File.read!("lib/relay/runs.ex")
      refute source =~ ~r/=\s*ensure_server\(/
    end
  end

  defp execution_outcome(job) do
    job = Repo.get!(NodeJob, job.id)
    Repo.get!(NodeExecution, job.node_execution_id).outcome
  end

  defp wait_for_queued_call(pid, attempts) when attempts > 0 do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} when n >= 1 ->
        :ok

      _ ->
        Process.sleep(5)
        wait_for_queued_call(pid, attempts - 1)
    end
  end

  defp wait_for_queued_call(_pid, 0), do: flunk("report_outcome never reached the RunServer mailbox")
end
