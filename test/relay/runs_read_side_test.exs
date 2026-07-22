defmodule Relay.RunsReadSideTest do
  use Relay.DataCase, async: true

  alias Relay.Flows
  alias Relay.Runs

  describe "happy_path/1" do
    test "walks the start edge then :succeeded edges to done" do
      board = insert(:board)

      {:ok, flow} =
        Flows.create_flow(board, %{
          key: "mini",
          isolation: :shared_clean,
          nodes: [
            %{key: "a", type: :agent, run: "a"},
            %{key: "b", type: :agent, run: "b"},
            %{key: "fix", type: :agent, run: "fix"}
          ],
          edges: [
            %{from: "start", to: "a"},
            %{from: "a", to: "b", on: :succeeded},
            %{from: "b", to: "fix", on: :failed},
            %{from: "fix", to: "b", on: :succeeded},
            %{from: "b", to: "done", on: :succeeded}
          ]
        })

      assert Runs.happy_path(flow) == ["a", "b"]
    end
  end

  describe "list_runs_for_card/1 and latest_run/1" do
    test "orders runs newest-first with chronological node executions" do
      card = insert(:card)
      old = insert(:run, card: card, status: :failed, inserted_at: ~U[2026-07-01 10:00:00Z])
      new = insert(:run, card: card, status: :running)
      first = insert(:node_execution, run: new, node: "branch", duration_s: 8)
      second = insert(:node_execution, run: new, node: "implement", outcome: nil, duration_s: nil)

      assert [got_new, got_old] = Runs.list_runs_for_card(card)
      assert got_new.id == new.id
      assert got_old.id == old.id
      assert Enum.map(got_new.node_executions, & &1.id) == [first.id, second.id]
      assert Runs.latest_run(card).id == new.id
    end
  end

  describe "run_summaries_for_board/1" do
    test "aggregates totals and locates the current node on the happy path" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Summaries"})
      board = Relay.Repo.preload(board, :stages)
      stage = hd(board.stages)
      card = insert(:card, stage: stage)
      run = insert(:run, card: card, flow_key: "code", current_node: "implement")
      insert(:node_execution, run: run, node: "branch", duration_s: 8, cost: Decimal.new("0.00"))
      insert(:node_execution, run: run, node: "implement", attempt: 1, duration_s: 160, cost: Decimal.new("0.90"))
      insert(:node_execution, run: run, node: "implement", attempt: 2, outcome: nil, duration_s: nil, cost: nil)

      summaries = Runs.run_summaries_for_board(board)
      summary = summaries[card.id]

      assert summary.status == :running
      assert summary.current_node == "implement"
      assert summary.node_index == 2
      assert summary.node_count > 2
      assert summary.nodes == 2
      assert summary.attempts == 3
      assert Decimal.equal?(summary.cost, Decimal.new("0.90"))
      assert summary.duration_s == 168
    end

    test "a board with no runs returns an empty map" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Empty"})

      assert Runs.run_summaries_for_board(board) == %{}
    end

    test "a live run's last_node is just its current_node" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Live"})
      board = Relay.Repo.preload(board, :stages)
      card = insert(:card, stage: hd(board.stages))
      run = insert(:run, card: card, flow_key: "code", current_node: "implement")
      insert(:node_execution, run: run, node: "branch")

      summary = Runs.run_summaries_for_board(board)[card.id]

      assert summary.current_node == "implement"
      assert summary.last_node == "implement"
    end

    test "a run closed :failed by close_run!/3 still names the node it died on" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Failed"})
      board = Relay.Repo.preload(board, :stages)
      card = insert(:card, stage: hd(board.stages))
      run = insert(:run, card: card, flow_key: "code", current_node: "quality_review")
      insert(:node_execution, run: run, node: "implement")
      insert(:node_execution, run: run, node: "quality_review", outcome: :failed)

      Runs.close_run!(run, :failed, "boom")

      summary = Runs.run_summaries_for_board(board)[card.id]

      assert summary.status == :failed
      assert is_nil(summary.current_node)
      assert summary.last_node == "quality_review"
    end

    test "a :cancelled run whose final execution is still in flight names that node" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Cancelled"})
      board = Relay.Repo.preload(board, :stages)
      card = insert(:card, stage: hd(board.stages))
      run = insert(:run, card: card, flow_key: "code", current_node: "implement")
      insert(:node_execution, run: run, node: "branch")
      insert(:node_execution, run: run, node: "implement", outcome: nil, duration_s: nil)

      Runs.close_run!(run, :cancelled, nil)

      summary = Runs.run_summaries_for_board(board)[card.id]

      assert is_nil(summary.current_node)
      assert summary.last_node == "implement"
    end

    test "a closed run with no executions has a nil last_node" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Bare"})
      board = Relay.Repo.preload(board, :stages)
      card = insert(:card, stage: hd(board.stages))
      run = insert(:run, card: card, flow_key: "code", current_node: "branch")

      Runs.close_run!(run, :failed, "died early")

      summary = Runs.run_summaries_for_board(board)[card.id]

      assert is_nil(summary.current_node)
      assert is_nil(summary.last_node)
    end

    test "breaker_tripped? is true only for a failed run whose failure_detail carries the circuit_breaker token" do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Breaker"})
      board = Relay.Repo.preload(board, :stages)
      stage = hd(board.stages)

      tripped_card = insert(:card, stage: stage)
      tripped_run = insert(:run, card: tripped_card, flow_key: "code", current_node: "implement")
      Runs.close_run!(tripped_run, :failed, "circuit_breaker: repeated 3 times")

      other_card = insert(:card, stage: stage)
      other_run = insert(:run, card: other_card, flow_key: "code", current_node: "implement")
      Runs.close_run!(other_run, :failed, "(no_route_for_outcome: fixit → failed)")

      summaries = Runs.run_summaries_for_board(board)

      assert summaries[tripped_card.id].breaker_tripped?
      refute summaries[other_card.id].breaker_tripped?
    end
  end

  describe "run_summary_for_card/1" do
    setup do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "OneCard"})
      board = Relay.Repo.preload(board, :stages)
      %{board: board, stage: hd(board.stages)}
    end

    test "matches that card's entry from run_summaries_for_board for an active run", %{board: board, stage: stage} do
      card = insert(:card, stage: stage)
      run = insert(:run, card: card, flow_key: "code", current_node: "implement")
      insert(:node_execution, run: run, node: "branch", duration_s: 8, cost: Decimal.new("0.10"))
      insert(:node_execution, run: run, node: "implement", attempt: 2, outcome: nil, duration_s: nil, cost: nil)

      assert Runs.run_summary_for_card(card) == Runs.run_summaries_for_board(board)[card.id]
    end

    test "matches the board entry for a terminal, multi-attempt run", %{board: board, stage: stage} do
      card = insert(:card, stage: stage)
      run = insert(:run, card: card, flow_key: "code", current_node: "quality_review")
      insert(:node_execution, run: run, node: "implement", attempt: 1, duration_s: 120, cost: Decimal.new("0.50"))
      insert(:node_execution, run: run, node: "implement", attempt: 2, duration_s: 90, cost: Decimal.new("0.40"))

      insert(:node_execution,
        run: run,
        node: "quality_review",
        outcome: :failed,
        duration_s: 30,
        cost: Decimal.new("0.10")
      )

      Runs.close_run!(run, :failed, "boom")

      assert Runs.run_summary_for_card(card) == Runs.run_summaries_for_board(board)[card.id]
    end

    test "returns nil for a card with no run", %{stage: stage} do
      card = insert(:card, stage: stage)
      assert Runs.run_summary_for_card(card) == nil
    end

    test "still summarizes when the flow row is gone (path [], node_count nil)", %{board: board, stage: stage} do
      card = insert(:card, stage: stage)
      run = insert(:run, card: card, flow_key: "ghost", current_node: "implement")
      insert(:node_execution, run: run, node: "implement")

      summary = Runs.run_summary_for_card(card)

      assert summary.node_count == nil
      assert summary.node_index == nil
      assert summary.current_node == "implement"
      assert summary == Runs.run_summaries_for_board(board)[card.id]
    end
  end

  describe "last_node/2" do
    test "prefers current_node, else the most recent execution (id breaks a same-second tie)" do
      now = DateTime.truncate(DateTime.utc_now(), :second)

      earlier = %{id: 1, node_key: "implement", started_at: now}
      later = %{id: 2, node_key: "quality_review", started_at: now}

      assert Runs.last_node(%{current_node: "implement"}, []) == "implement"
      assert Runs.last_node(%{current_node: nil}, [earlier, later]) == "quality_review"
      assert Runs.last_node(%{current_node: nil}, [later, earlier]) == "quality_review"
      assert Runs.last_node(%{current_node: nil}, []) == nil
    end
  end

  describe "queued_flow/4" do
    setup do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Queued"})
      board = Relay.Repo.preload(board, :stages)
      flow = Flows.get_flow!(board, "code")
      {:ok, flow} = Flows.enable_flow(flow)
      pulls_from = Enum.find(board.stages, &(&1.id == flow.pulls_from_stage_id))
      %{board: board, flow: flow, pulls_from: pulls_from}
    end

    test "ready + AI baton + enabled flow pulls from stage + no active run", ctx do
      card = insert(:card, stage: ctx.pulls_from, status: :ready)

      assert %Schemas.Flow{key: "code"} = Runs.queued_flow(card, :ai, [ctx.flow], nil)
    end

    test "not queued when the baton is human, the flow is disabled, or a run is active", ctx do
      card = insert(:card, stage: ctx.pulls_from, status: :ready)

      refute Runs.queued_flow(card, :human, [ctx.flow], nil)
      refute Runs.queued_flow(card, :ai, [%{ctx.flow | enabled: false}], nil)
      refute Runs.queued_flow(card, :ai, [ctx.flow], %{status: :running})
      refute Runs.queued_flow(%{card | status: :working}, :ai, [ctx.flow], nil)
    end

    test "queued for a :queued-status card and for an unowned ready card (RLY-206 face nudge)", ctx do
      queued = insert(:card, stage: ctx.pulls_from, status: :queued)
      unowned = insert(:card, stage: ctx.pulls_from, status: :ready)

      assert %Schemas.Flow{key: "code"} = Runs.queued_flow(queued, :ai, [ctx.flow], nil)
      assert %Schemas.Flow{key: "code"} = Runs.queued_flow(unowned, nil, [ctx.flow], nil)
    end
  end

  describe "face_summary/4" do
    setup do
      user = insert(:user)
      {:ok, board} = Relay.Boards.create_board(user, %{name: "Face"})
      board = Relay.Repo.preload(board, :stages)
      flow = Flows.get_flow!(board, "code")
      {:ok, flow} = Flows.enable_flow(flow)
      %{board: board, flow: flow}
    end

    test "an active run wins regardless of stage", ctx do
      card = insert(:card, stage: hd(ctx.board.stages), status: :working)
      summary = %{status: :running, flow_key: "code"}

      assert {:run, ^summary} = Runs.face_summary(card, :ai, [ctx.flow], %{card.id => summary})
    end

    test "a terminal run stays on the face while the card sits in the flow's trigger stages", ctx do
      lands_on = Enum.find(ctx.board.stages, &(&1.id == ctx.flow.lands_on_stage_id))
      card = insert(:card, stage: lands_on, status: :in_review)
      summary = %{status: :done, flow_key: "code"}

      assert {:run, ^summary} = Runs.face_summary(card, :human, [ctx.flow], %{card.id => summary})
    end

    test "a terminal run drops off once the card moves on", ctx do
      elsewhere =
        Enum.find(ctx.board.stages, fn s ->
          s.id not in [
            ctx.flow.pulls_from_stage_id,
            ctx.flow.works_in_stage_id,
            ctx.flow.lands_on_stage_id
          ]
        end)

      card = insert(:card, stage: elsewhere, status: :ready)
      summary = %{status: :done, flow_key: "code"}

      assert Runs.face_summary(card, nil, [ctx.flow], %{card.id => summary}) == nil
    end

    test "queued when no run and the enabled flow pulls from the card's stage", ctx do
      pulls_from = Enum.find(ctx.board.stages, &(&1.id == ctx.flow.pulls_from_stage_id))
      card = insert(:card, stage: pulls_from, status: :ready)

      assert {:queued, %Schemas.Flow{key: "code"}} =
               Runs.face_summary(card, :ai, [ctx.flow], %{})
    end

    test "an unowned ready card on a pulls-from stage shows the queued pill (RLY-206 nudge)", ctx do
      pulls_from = Enum.find(ctx.board.stages, &(&1.id == ctx.flow.pulls_from_stage_id))
      card = insert(:card, stage: pulls_from, status: :ready)

      assert {:queued, %Schemas.Flow{key: "code"}} =
               Runs.face_summary(card, nil, [ctx.flow], %{})
    end
  end

  describe "pubsub seam" do
    test "broadcast_run_changed reaches subscribers of the board's runs topic" do
      Runs.subscribe(42)
      Runs.broadcast_run_changed(42, 7)

      assert_receive {:run_changed, 7}
    end
  end
end
